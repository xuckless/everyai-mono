import '../../../core/db/app_database.dart';
import '../../../core/preferences.dart';
import '../../memory/memory_providers.dart';

/// Preferences keyed by conversation id. `chat.effort.` is the reasoning
/// effort picked per chat (`ReasoningEffort.prefKey`).
const _perChat = ['chat.effort.'];

/// Preferences keyed by tool call id (quiz answers, flashcard progress).
const _perCall = ['artifacts.quiz.', 'artifacts.cards.'];

/// Deletes blobs (generated images, attachments) that no message part refers to any more, which is what is left
/// after chats or messages are deleted. Returns how many went. Meant to run in the background at launch.
Future<int> collectBlobGarbage(AppDatabase db) {
  return db.customUpdate(
    'DELETE FROM blobs WHERE id NOT IN (SELECT blob_id FROM message_parts WHERE blob_id IS NOT NULL)',
    updates: {db.blobs},
  );
}

/// Removes per-chat Preferences whose chat no longer exists: the keys above,
/// each deleted chat's memory pointer and the memory blocks no chat uses.
/// Runs at launch and after a chat is deleted.
Future<void> sweepChatPreferences(AppDatabase db, Preferences prefs) async {
  final chats = {for (final row in await db.customSelect('SELECT id FROM conversations').get()) row.read<String>('id')};
  bool gone(String id) => !chats.contains(id);
  for (final prefix in _perChat) {
    for (final k in prefs.keysStartingWith(prefix)) {
      if (gone(k.substring(prefix.length))) prefs[k] = null;
    }
  }
  MemorySnapshots(prefs).forgetChats(gone);

  final callKeys = [for (final p in _perCall) ...prefs.keysStartingWith(p).map((k) => (k, k.substring(p.length)))];
  if (callKeys.isEmpty) return;
  final calls = {
    for (final row
        in await db
            .customSelect("SELECT json_extract(body, '\$.id') AS id FROM message_parts WHERE kind = 'tool_call'")
            .get())
      ?row.readNullable<String>('id'),
  };
  for (final (key, callId) in callKeys) {
    if (!calls.contains(callId)) prefs[key] = null;
  }
}
