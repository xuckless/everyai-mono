// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

/// What a finished agent() call answered: [value] when [ok], else [error].
/// [spentMicros]: what it cost EveryAI (null on an outside harness).
typedef JournalledAgent = ({bool ok, Object? value, String? error, int? spentMicros});

/// One workflow run's steps, one JSON object per line, so a run the app
/// quit in the middle of can carry on (`workflows/<session>/<run>.jsonl`):
/// - `{t:"start", name, source, args, at}` (`at`: epoch milliseconds)
/// - `{t:"spawn", key, child}`: the agent's child session started
/// - `{t:"agent", key, ok, value|error, spent?}`: it finished
/// - `{t:"phase", title}`
/// - `{t:"stop", outcome, why, quiet?}`: stopped by the user or a cap (`quiet`: by Stop all, the lead isn't told)
/// - `{t:"ending", outcome, result?, error?}`: the shutdown began
///
/// A resume of a journal with a stop, an ending or an end runs only the shutdown, never the script again; the
/// journal is retired once the lead has the result.
/// - `{t:"end", status, result?, error?}`
///
/// A torn last line (the app quit mid-write) is skipped.
final class WorkflowJournal {
  WorkflowJournal._(this._append);

  /// An empty journal written through [append] (one line at a time).
  WorkflowJournal.fresh(Future<void> Function(String line) append) : this._(append);

  /// The journal [text] holds, written on through [append].
  factory WorkflowJournal.parse(String text, Future<void> Function(String line) append) {
    final j = WorkflowJournal._(append);
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      try {
        if (jsonDecode(line) case final Map<String, Object?> m) j._apply(m);
      } on FormatException {
        // A torn line.
      }
    }
    return j;
  }

  final Future<void> Function(String line) _append;
  Future<void> _tail = Future.value();

  Map<String, Object?>? start;
  final spawns = <String, String>{};
  final agents = <String, JournalledAgent>{};
  final phases = <String>[];

  /// Rows on the run's card (phase reports, marks), and the guard marks passed (see workflow_guard.dart).
  final rows = <({String kind, String phase, String text})>[];
  final marks = <String>{};

  /// Each time the user let it go on past its estimate: what it had spent then (so the marks it skipped stay skipped).
  final raiseSpends = <int>[];
  int get raises => raiseSpends.length;

  /// A drift check paused it, and the user hasn't let it go on yet: a resume holds again.
  var heldOffTrack = false;

  /// Phases whose drift check ran (not run again after a restart).
  final driftChecked = <String>{};
  Map<String, Object?>? stop;
  Map<String, Object?>? ending;
  Map<String, Object?>? end;

  bool get ended => end != null;

  void _apply(Map<String, Object?> m) {
    switch (m['t']) {
      case 'start':
        start = m;
      case 'spawn':
        spawns['${m['key']}'] = '${m['child']}';
      case 'agent':
        agents['${m['key']}'] = (
          ok: m['ok'] == true,
          value: m['value'],
          error: m['error'] as String?,
          spentMicros: m['spent'] is int ? m['spent'] as int : null,
        );
      case 'phase':
        phases.add('${m['title']}');
      case 'row':
        rows.add((kind: '${m['kind']}', phase: '${m['phase'] ?? ''}', text: '${m['text']}'));
        if (m['mark'] case final String id) marks.add(id);
      case 'raise':
        raiseSpends.add(m['spent'] is int ? m['spent']! as int : 0);
      case 'hold':
        if (m['reason'] == 'offTrack') heldOffTrack = true;
      case 'go':
        heldOffTrack = false;
      case 'drift':
        driftChecked.add('${m['phase']}');
      case 'stop':
        stop ??= m;
      case 'ending':
        ending ??= m;
      case 'end':
        end = m;
    }
  }

  /// Records [line] and appends it after every earlier write.
  Future<void> write(Map<String, Object?> line) {
    _apply(line);
    final text = jsonEncode(line);
    final next = _tail.then((_) => _append(text));
    _tail = next.catchError((Object _) {});
    return next;
  }

  /// Every write so far has landed.
  Future<void> get flushed => _tail;
}
