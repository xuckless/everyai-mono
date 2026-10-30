import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/preferences.dart';
import '../../core/providers.dart';
import '../chat/data/chat_repository.dart';
import 'data/chat_recall.dart';
import 'domain/memory.dart';

/// The client-executed tools for memory and chat recall (`client_tools`).
const memoryTool = 'memory';
const searchChatsTool = 'search_chats';
const localChatTools = {memoryTool, searchChatsTool};

final memoryProvider = NotifierProvider<MemoryController, Memory>(MemoryController.new);

/// The user's memory, saved in Preferences under [MemoryController.key].
final class MemoryController extends Notifier<Memory> {
  static const key = 'memory.v1';

  Preferences get _prefs => ref.read(preferencesProvider);

  @override
  Memory build() => Memory.decode(ref.read(preferencesProvider)[key]);

  void _save(Memory next) {
    if (next == state) return;
    state = next;
    _prefs[key] = next.encode();
  }

  void setEnabled(bool enabled) => _save(state.copyWith(enabled: enabled));

  /// Runs one `memory` tool call and saves the result.
  MemoryEdit apply(Map<String, Object?> args) {
    final edit = applyMemoryEdit(state, args);
    if (!edit.isError) _save(edit.memory);
    return edit;
  }

  /// Settings → Memory: replaces a note's entries as the user edited them.
  void setEntries(MemoryTarget target, List<String> entries) => _save(
    state.withEntries(target, [
      for (final e in entries.map(normalizeEntry))
        if (e.isNotEmpty) e,
    ]),
  );

  /// Empties both notes and drops every chat's frozen copy of them.
  void clear() {
    _save(state.copyWith(user: const [], notes: const []));
    MemorySnapshots(_prefs).clearAll();
  }

  /// The memory block for [chatId]: taken from the current notes on the
  /// chat's first turn, then the same text on every later turn.
  String? snapshotFor(String chatId) => MemorySnapshots(_prefs).take(chatId, () => memoryBlock(state));
}

/// Per-chat frozen memory blocks in Preferences. Chats point at a
/// content-addressed text (most chats share one), so storage stays small.
final class MemorySnapshots {
  MemorySnapshots(this._prefs);

  final Preferences _prefs;

  static const _chat = 'memory.chat.';
  static const _text = 'memory.snap.';
  static const _index = 'memory.snaps';

  /// The chat's snapshot, taking one with [current] if it has none. Null when
  /// memory was off as the chat began (or its copy was cleared).
  String? take(String chatId, String? Function() current) {
    if (_prefs['$_chat$chatId'] case final id?) return id.isEmpty ? null : _prefs['$_text$id'];
    final block = current();
    if (block == null) {
      _prefs['$_chat$chatId'] = '';
      return null;
    }
    final id = fingerprint(block);
    _prefs['$_text$id'] = block;
    final ids = _ids();
    if (!ids.contains(id)) _prefs[_index] = jsonEncode([...ids, id]);
    _prefs['$_chat$chatId'] = id;
    return block;
  }

  List<String> _ids() {
    try {
      return switch (jsonDecode(_prefs[_index] ?? '[]')) {
        final List<Object?> l => l.whereType<String>().toList(),
        _ => const [],
      };
    } on FormatException {
      return const [];
    }
  }

  /// Drops every stored block; chats that had one go on without memory.
  void clearAll() {
    for (final id in _ids()) {
      _prefs['$_text$id'] = null;
    }
    _prefs[_index] = null;
  }
}

/// What a local tool call returns to the model.
typedef LocalToolResult = ({String text, bool isError});

/// Runs `memory` and `search_chats` calls on this device.
final class LocalChatTools {
  const LocalChatTools({required this.editMemory, required this.recall});

  final MemoryEdit Function(Map<String, Object?> args) editMemory;
  final ChatRecall recall;

  bool handles(String name) => localChatTools.contains(name);

  /// Never throws: a failure is an error result the model can read.
  Future<LocalToolResult> run(String name, String argumentsJson, {required String chatId}) async {
    final Map<String, Object?> args;
    try {
      args = switch (jsonDecode(argumentsJson)) {
        final Map<String, Object?> m => m,
        _ => const {},
      };
    } on FormatException {
      return (text: 'Error: the arguments were not valid JSON.', isError: true);
    }
    try {
      switch (name) {
        case memoryTool:
          final edit = editMemory(args);
          return (text: edit.text, isError: edit.isError);
        case searchChatsTool:
          if (args['chat_id'] case final String id when id.trim().isNotEmpty) {
            final text = await recall.readText(id.trim());
            return text == null
                ? (text: 'Error: no chat has chat_id "$id". Use a chat_id from search results.', isError: true)
                : (text: text, isError: false);
          }
          final query = (args['query'] as String? ?? '').trim();
          if (query.isEmpty) return (text: 'Error: give a query or a chat_id.', isError: true);
          final limit = args['limit'] is num ? (args['limit'] as num).toInt() : 8;
          return (text: await recall.searchText(query, excludeChat: chatId, limit: limit), isError: false);
      }
    } on Object catch (e) {
      return (text: 'Error: $name failed on the device ($e).', isError: true);
    }
    return (text: 'Error: unknown tool $name.', isError: true);
  }
}

final localChatToolsProvider = Provider<LocalChatTools>(
  (ref) => LocalChatTools(
    editMemory: (args) => ref.read(memoryProvider.notifier).apply(args),
    recall: ChatRecall(ref.watch(databaseProvider), ChatRepository(ref.watch(databaseProvider))),
  ),
);

/// The local tools the chat declares (`client_tools`): none when memory is off.
final enabledLocalChatToolsProvider = Provider<Set<String>>(
  (ref) => ref.watch(memoryProvider.select((m) => m.enabled)) ? localChatTools : const {},
);

/// The stored outcome of a local tool call ([ToolCallPart.resultJson]).
String localToolResultJson(LocalToolResult r) => jsonEncode({'text': r.text, 'error': r.isError});
