// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../harness/events.dart';
import 'event_journal_stub.dart' if (dart.library.io) 'event_journal_io.dart' as impl;

/// The events an outside driver emitted for one conversation, kept as JSON
/// lines in `[dir]/<conversationId>.jsonl` so `attach` can replay the
/// transcript after an app restart. For CLIs whose own history can't be
/// read back in our event shapes. Streaming deltas aren't kept.
abstract interface class EventJournal {
  /// Appends [event] (its `raw` JSON). Writes are serialised.
  void add(HarnessEvent event);

  /// Every event kept so far, oldest first; a torn last line is skipped.
  Future<List<HarnessEvent>> read();

  Future<void> close();
}

EventJournal openEventJournal(String dir, String conversationId) => impl.openEventJournal(dir, conversationId);

/// The last events in the JSON-lines file at [path] (at most its final [maxBytes]; a cut first line is skipped).
/// Empty when the file is missing or off this platform. For lists that show what a closed session last did.
Future<List<HarnessEvent>> readEventTail(String path, {int maxBytes = 96 * 1024}) =>
    impl.readEventTail(path, maxBytes: maxBytes);

/// The file [openEventJournal] keeps [conversationId]'s events in.
String eventJournalPath(String dir, String conversationId) =>
    '$dir/${conversationId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.jsonl';
