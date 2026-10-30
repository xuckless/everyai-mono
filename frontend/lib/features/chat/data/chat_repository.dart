import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart';
import '../../models/domain/model_catalog.dart';
import '../domain/message.dart';

/// Persists conversations and messages. Reads are reactive: watch* streams
/// emit again whenever the underlying tables change (no polling).
final class ChatRepository {
  ChatRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  String newId() => _uuid.v7();

  Stream<List<Conversation>> watchConversations() {
    final q = _db.select(_db.conversations)
      ..where((c) => c.archived.equals(false))
      ..orderBy([(c) => OrderingTerm.desc(c.pinned), (c) => OrderingTerm.desc(c.updatedAt)]);
    return q.watch().map((rows) => rows.map(_toConversation).toList(growable: false));
  }

  Future<Conversation?> conversation(String id) async {
    final row = await (_db.select(_db.conversations)..where((c) => c.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toConversation(row);
  }

  Future<List<Message>> messages(String conversationId) async {
    final rows =
        await (_db.select(_db.messages)
              ..where((m) => m.conversationId.equals(conversationId))
              // rowid breaks ties: it follows insertion order, and upserts keep it.
              ..orderBy([
                (m) => OrderingTerm.asc(m.createdAt),
                (_) => OrderingTerm.asc(const CustomExpression<int>('messages.rowid')),
              ]))
            .get();
    if (rows.isEmpty) return const [];

    final ids = rows.map((r) => r.id).toList();
    final partRows =
        await (_db.select(_db.messageParts)
              ..where((p) => p.messageId.isIn(ids))
              ..orderBy([(p) => OrderingTerm.asc(p.idx)]))
            .get();
    final blobIds = partRows.map((p) => p.blobId).nonNulls.toSet();
    final blobs = blobIds.isEmpty
        ? const <String, BlobRow>{}
        : {for (final b in await (_db.select(_db.blobs)..where((b) => b.id.isIn(blobIds))).get()) b.id: b};

    final partsByMessage = <String, List<MessagePart>>{};
    for (final p in partRows) {
      (partsByMessage[p.messageId] ??= []).add(_toPart(p, blobs));
    }
    return [
      for (final r in rows)
        Message(
          id: r.id,
          conversationId: r.conversationId,
          role: Role.values.byName(r.role),
          parts: partsByMessage[r.id] ?? const [],
          createdAt: r.createdAt,
          model: r.modelId == null ? null : ModelId(r.modelId!),
          status: MessageStatus.values.byName(r.status),
          error: r.error,
        ),
    ];
  }

  Future<Conversation> createConversationWithId({
    required String id,
    required String title,
    required ModelId model,
  }) async {
    final now = DateTime.now();
    final c = Conversation(id: id, title: title, model: model, createdAt: now, updatedAt: now);
    await _db
        .into(_db.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: c.id,
            title: c.title,
            modelId: c.model.value,
            createdAt: now,
            updatedAt: now,
          ),
        );
    return c;
  }

  /// Writes a finished message and its parts atomically, and bumps the conversation.
  Future<void> saveMessage(Message m) => _db.transaction(() async {
    await _db
        .into(_db.messages)
        .insertOnConflictUpdate(
          MessagesCompanion.insert(
            id: m.id,
            conversationId: m.conversationId,
            role: m.role.name,
            modelId: Value(m.model?.value),
            status: m.status.name,
            error: Value(m.error),
            createdAt: m.createdAt,
          ),
        );
    await (_db.delete(_db.messageParts)..where((p) => p.messageId.equals(m.id))).go();
    for (final (i, part) in m.parts.indexed) {
      await _db.into(_db.messageParts).insert(await _partCompanion(m.id, i, part));
    }
    await (_db.update(
      _db.conversations,
    )..where((c) => c.id.equals(m.conversationId))).write(ConversationsCompanion(updatedAt: Value(DateTime.now())));
  });

  /// Deletes the given messages (and their parts). Used by edit and regenerate.
  Future<void> deleteMessages(Iterable<String> ids) =>
      (_db.delete(_db.messages)..where((m) => m.id.isIn(ids.toList()))).go();

  Future<void> rename(String conversationId, String title) => (_db.update(
    _db.conversations,
  )..where((c) => c.id.equals(conversationId))).write(ConversationsCompanion(title: Value(title)));

  Future<void> setPinned(String conversationId, {required bool pinned}) => (_db.update(
    _db.conversations,
  )..where((c) => c.id.equals(conversationId))).write(ConversationsCompanion(pinned: Value(pinned)));

  Future<void> delete(String conversationId) =>
      (_db.delete(_db.conversations)..where((c) => c.id.equals(conversationId))).go();

  /// Conversation ids whose messages match [query], best match first.
  Future<List<String>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final List<QueryRow> rows;
    if (await _db.hasSearchIndex) {
      // Quote each term so FTS syntax characters in user input are literal.
      final match = q.split(RegExp(r'\s+')).map((t) => '"${t.replaceAll('"', '""')}"*').join(' ');
      rows = await _db
          .customSelect(
            'SELECT DISTINCT m.conversation_id AS cid FROM message_search s '
            'JOIN messages m ON m.id = s.message_id WHERE message_search MATCH ? ORDER BY rank LIMIT 50',
            variables: [Variable.withString(match)],
            readsFrom: {_db.messages, _db.messageParts},
          )
          .get();
    } else {
      rows = await _db
          .customSelect(
            'SELECT DISTINCT m.conversation_id AS cid FROM message_parts p JOIN messages m ON m.id = p.message_id '
            "WHERE p.kind = 'text' AND p.body LIKE ? ESCAPE '\\' LIMIT 50",
            variables: [
              Variable.withString('%${q.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%'),
            ],
            readsFrom: {_db.messages, _db.messageParts},
          )
          .get();
    }
    return rows.map((r) => r.read<String>('cid')).toList();
  }

  Future<MessagePartsCompanion> _partCompanion(String messageId, int idx, MessagePart part) async {
    switch (part) {
      case TextPart(:final text):
        return MessagePartsCompanion.insert(messageId: messageId, idx: idx, kind: 'text', body: Value(text));
      case ImagePart(:final bytes, :final blobRef, :final mimeType):
        var ref = blobRef;
        if (ref == null) {
          ref = newId();
          await _db.into(_db.blobs).insert(BlobsCompanion.insert(id: ref, bytes: bytes!, mimeType: mimeType));
        }
        return MessagePartsCompanion.insert(
          messageId: messageId,
          idx: idx,
          kind: 'image',
          blobId: Value(ref),
          mimeType: Value(mimeType),
        );
      case SourcesPart(:final sources):
        return MessagePartsCompanion.insert(
          messageId: messageId,
          idx: idx,
          kind: 'sources',
          body: Value(jsonEncode([for (final s in sources) s.toJson()])),
        );
      case FollowUpsPart(:final questions):
        return MessagePartsCompanion.insert(
          messageId: messageId,
          idx: idx,
          kind: 'followups',
          body: Value(jsonEncode(questions)),
        );
      case ToolCallPart(:final toolName, :final argumentsJson, :final resultJson):
        return MessagePartsCompanion.insert(
          messageId: messageId,
          idx: idx,
          kind: 'tool_call',
          body: Value(jsonEncode({'tool': toolName, 'args': argumentsJson, 'result': resultJson})),
        );
      case ArtifactPart(:final artifactId, :final title, :final kind):
        return MessagePartsCompanion.insert(
          messageId: messageId,
          idx: idx,
          kind: 'artifact',
          body: Value(jsonEncode({'kind': kind, 'id': artifactId, 'title': title})),
        );
    }
  }

  static MessagePart _toPart(MessagePartRow p, Map<String, BlobRow> blobs) => switch (p.kind) {
    'image' => ImagePart(bytes: blobs[p.blobId]?.bytes, blobRef: p.blobId, mimeType: p.mimeType ?? 'image/webp'),
    'artifact' => _artifact(p.body ?? '{}'),
    'tool_call' => _toolCall(p.body ?? '{}'),
    'sources' => SourcesPart(
      (jsonDecode(p.body ?? '[]') as List<Object?>).map(Source.fromJson).nonNulls.toList(growable: false),
    ),
    'followups' => FollowUpsPart(
      (jsonDecode(p.body ?? '[]') as List<Object?>).whereType<String>().toList(growable: false),
    ),
    _ => TextPart(p.body ?? ''),
  };

  static MessagePart _artifact(String body) => switch (jsonDecode(body)) {
    {'kind': final String kind, 'id': final String id, 'title': final String title} => ArtifactPart(
      artifactId: id,
      title: title,
      kind: kind,
    ),
    _ => const TextPart(''),
  };

  static MessagePart _toolCall(String body) => switch (jsonDecode(body)) {
    {'tool': final String tool, 'args': final String args, 'result': final String? result} => ToolCallPart(
      toolName: tool,
      argumentsJson: args,
      resultJson: result,
    ),
    _ => const TextPart(''),
  };

  static Conversation _toConversation(ConversationRow r) => Conversation(
    id: r.id,
    title: r.title,
    model: ModelId(r.modelId),
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    pinned: r.pinned,
  );
}
