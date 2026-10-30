import 'package:drift/drift.dart';

import '../../../core/db/app_database.dart';
import '../../chat/data/chat_repository.dart';

/// One message that matched a `search_chats` query.
typedef RecallHit = ({String chatId, String title, DateTime at, String role, String snippet});

/// The `search_chats` tool: the local full-text index (`message_search`) over
/// earlier chats, run by the app so history never leaves the device except
/// for the snippets the model asked for.
final class ChatRecall {
  ChatRecall(this._db, this._repo);

  final AppDatabase _db;
  final ChatRepository _repo;

  /// The most characters of one message when reading a chat.
  static const messageCap = 2000;

  /// The most characters a whole chat read returns.
  static const readCap = 12000;

  /// Messages matching [query] outside [excludeChat], best first. All terms
  /// must match; when none do, any term may.
  Future<List<RecallHit>> search(String query, {String? excludeChat, int limit = 8}) async {
    final terms = query.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (terms.isEmpty) return const [];
    if (!await _db.hasSearchIndex) return _searchLike(query.trim(), excludeChat, limit);
    String match(String joiner) => terms.map((t) => '"${t.replaceAll('"', '""')}"*').join(joiner);
    final all = await _searchFts(match(' '), excludeChat, limit);
    if (all.isNotEmpty || terms.length == 1) return all;
    return _searchFts(match(' OR '), excludeChat, limit);
  }

  Future<List<RecallHit>> _searchFts(String match, String? excludeChat, int limit) async {
    final rows = await _db
        .customSelect(
          'SELECT m.conversation_id AS cid, c.title AS title, m.role AS role, m.created_at AS at, '
          "snippet(message_search, 0, '[', ']', '…', 24) AS snip "
          'FROM message_search s JOIN messages m ON m.id = s.message_id '
          'JOIN conversations c ON c.id = m.conversation_id '
          'WHERE message_search MATCH ? AND m.conversation_id != ? ORDER BY rank LIMIT ?',
          variables: [Variable.withString(match), Variable.withString(excludeChat ?? ''), Variable.withInt(limit)],
          readsFrom: {_db.messages, _db.messageParts, _db.conversations},
        )
        .get();
    return rows.map(_hit).toList(growable: false);
  }

  Future<List<RecallHit>> _searchLike(String query, String? excludeChat, int limit) async {
    final escaped = query.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
    final rows = await _db
        .customSelect(
          'SELECT m.conversation_id AS cid, c.title AS title, m.role AS role, m.created_at AS at, p.body AS snip '
          'FROM message_parts p JOIN messages m ON m.id = p.message_id '
          'JOIN conversations c ON c.id = m.conversation_id '
          "WHERE p.kind = 'text' AND p.body LIKE ? ESCAPE '\\' AND m.conversation_id != ? "
          'ORDER BY m.created_at DESC LIMIT ?',
          variables: [
            Variable.withString('%$escaped%'),
            Variable.withString(excludeChat ?? ''),
            Variable.withInt(limit),
          ],
          readsFrom: {_db.messages, _db.messageParts, _db.conversations},
        )
        .get();
    return [
      for (final r in rows)
        (
          chatId: r.read<String>('cid'),
          title: r.read<String>('title'),
          at: r.read<DateTime>('at'),
          role: r.read<String>('role'),
          snippet: likeSnippet(r.read<String>('snip'), query),
        ),
    ];
  }

  RecallHit _hit(QueryRow r) => (
    chatId: r.read<String>('cid'),
    title: r.read<String>('title'),
    at: r.read<DateTime>('at'),
    role: r.read<String>('role'),
    snippet: r.read<String>('snip').replaceAll(RegExp(r'\s+'), ' '),
  );

  /// The text the model reads for a search.
  Future<String> searchText(String query, {String? excludeChat, int limit = 8}) async {
    final hits = await search(query, excludeChat: excludeChat, limit: limit.clamp(1, 20));
    if (hits.isEmpty) return 'No earlier chats match "$query".';
    final b = StringBuffer('${hits.length} match(es) in earlier chats, best first (matched words in [brackets]):\n');
    for (final (i, h) in hits.indexed) {
      b.writeln('${i + 1}. "${h.title}" (chat_id ${h.chatId}, ${_day(h.at)}), ${h.role}: ${h.snippet}');
    }
    b.write('Call search_chats with a chat_id to read that chat.');
    return b.toString();
  }

  /// The text the model reads for one chat: its messages, oldest first, each
  /// cut at [messageCap] and the whole at [readCap]. Null when it's unknown.
  Future<String?> readText(String chatId) async {
    final chat = await _repo.conversation(chatId);
    if (chat == null) return null;
    final b = StringBuffer('Chat "${chat.title}" (${_day(chat.createdAt)}):\n');
    for (final m in await _repo.messages(chatId)) {
      var text = m.plainText.trim();
      if (text.isEmpty) continue;
      if (text.length > messageCap) text = '${text.substring(0, messageCap)}…';
      final line = '\n${m.role.name}: $text\n';
      if (b.length + line.length > readCap) {
        b.write('\n[The rest of this chat is left out.]');
        break;
      }
      b.write(line);
    }
    return b.toString();
  }
}

String _day(DateTime at) => at.toIso8601String().substring(0, 10);

/// About [radius] characters each side of [query]'s first match in [body].
String likeSnippet(String body, String query, {int radius = 120}) {
  final flat = body.replaceAll(RegExp(r'\s+'), ' ');
  final at = flat.toLowerCase().indexOf(query.toLowerCase());
  if (at < 0) return flat.length <= radius * 2 ? flat : '${flat.substring(0, radius * 2)}…';
  final start = (at - radius).clamp(0, flat.length);
  final end = (at + query.length + radius).clamp(0, flat.length);
  return '${start > 0 ? '…' : ''}${flat.substring(start, end)}${end < flat.length ? '…' : ''}';
}
