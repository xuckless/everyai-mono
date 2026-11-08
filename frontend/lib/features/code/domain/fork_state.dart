// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

import 'subagents.dart' show SubagentStatus;

// A fork's lifecycle (a `run_subagent` child or a host `fork`), as its lead's session keeps it:
//
//   spawning ──its child started──▶ running ◀──────────────────────────────┐
//      │                              │ ──a question for the lead──▶ waitingOnLead(ask) ──answered──┤
//      │                              │ ──an approval or consent──▶ waitingOnUser ──decided─────────┤
//      │                              │ ──Pause──▶ pausing ──its step ended──▶ paused ──Resume──────┤
//      │                              │ ──retried on the lead's model──▶ spawning                   │
//      │                              │ ──stop_fork / Stop──▶ stopping ──┐                          │
//      │                              └──its turn ended──────────────────┴─▶ merging ──▶ reported ──┘ it works
//      │                                                    (no worktree: straight to reported)       again: its
//      ├──stopped while it started, couldn't start, over the limit──▶ dropped                        next report
//      └ (any state but reported) ──Stop all──▶ dropped                                                is a follow-up
//
// Questions go to the lead first ([AskRoute]): only approvals and consent wait on the user. A fork is reported
// once per turn; one that works again after its report goes back to running, and its next report says so.

/// A session's hold after its current step (Pause), for forks, workflow agents and any session:
///
///   none ──Pause──▶ pausing ──the step it was on ended (its turn, or its next call is held)──▶ paused ──Resume──▶ none
///                      └──Resume──▶ none
///
/// Held, it starts no new step: its next tool call waits unanswered, and messages queue. What it started (shells,
/// servers) keeps running.
enum StepHold { none, pausing, paused }

/// How a fork's report reaches its lead: as the result of the call that started it (a held call), or as a task
/// notification (it runs in the background).
enum ForkDelivery { call, notification }

/// Where one of a fork's questions went.
@immutable
sealed class AskRoute {
  const AskRoute(this.questionId);

  /// The question card's call id in the fork's session.
  final String questionId;
}

/// Passed to the lead (a `<fork-question>`); it answers with answer_fork, asking the user first when it must.
final class AskToLead extends AskRoute {
  const AskToLead(super.questionId);
}

final class AskAnsweredByLead extends AskRoute {
  const AskAnsweredByLead(super.questionId);
}

/// The user answered it in the fork's own view first; the lead was told, so it doesn't answer too.
final class AskAnsweredByUser extends AskRoute {
  const AskAnsweredByUser(super.questionId);
}

@immutable
sealed class ForkState {
  const ForkState();

  /// Whether the fork still counts as at work (toward the limit, Stop all, end_workflow, the lead's busy state).
  bool get live => true;

  /// Whether it has a child session that works (or can be paused or stopped).
  bool get working => false;

  String get name;

  @override
  String toString() => name;
}

final class ForkSpawning extends ForkState {
  const ForkSpawning();
  @override
  String get name => 'spawning';
}

final class ForkRunning extends ForkState {
  const ForkRunning({this.followUp = false});

  /// It works again after it reported: its next report is a follow-up.
  final bool followUp;
  @override
  bool get working => true;
  @override
  String get name => followUp ? 'running(follow-up)' : 'running';
}

final class ForkWaitingOnLead extends ForkState {
  const ForkWaitingOnLead(this.ask);
  final AskToLead ask;
  @override
  bool get working => true;
  @override
  String get name => 'waitingOnLead';
}

final class ForkWaitingOnUser extends ForkState {
  const ForkWaitingOnUser();
  @override
  bool get working => true;
  @override
  String get name => 'waitingOnUser';
}

/// Asked to hold: it ends the step it is on first.
final class ForkPausing extends ForkState {
  const ForkPausing();
  @override
  bool get working => true;
  @override
  String get name => 'pausing';
}

final class ForkPaused extends ForkState {
  const ForkPaused();
  @override
  bool get working => true;
  @override
  String get name => 'paused';
}

final class ForkStopping extends ForkState {
  const ForkStopping();
  @override
  String get name => 'stopping';
}

/// Its work is being merged back (after its batch check, when it has one).
final class ForkMerging extends ForkState {
  const ForkMerging();
  @override
  String get name => 'merging';
}

final class ForkReported extends ForkState {
  const ForkReported(this.status);
  final SubagentStatus status;
  @override
  bool get live => false;
  @override
  String get name => 'reported(${status.name})';
}

/// Ended with nothing more to tell its lead: stopped before it started, couldn't start, or Stop all.
final class ForkDropped extends ForkState {
  const ForkDropped(this.why);
  final String why;
  @override
  bool get live => false;
  @override
  String get name => 'dropped';
}

/// Whether [from] → [to] is an edge of the diagram.
bool forkEdge(ForkState from, ForkState to) => switch ((from, to)) {
  (ForkSpawning(), ForkRunning(followUp: false) || ForkDropped() || ForkStopping()) => true,
  // A child that works: between its working states (paused only through pausing), back to spawning for a retry on
  // the lead's model, or on to its end.
  (_, ForkPaused()) when from is! ForkPausing && from is! ForkPaused => false,
  (ForkPaused(), ForkPaused()) => false,
  (ForkRunning() || ForkWaitingOnLead() || ForkWaitingOnUser() || ForkPausing() || ForkPaused(), _) => switch (to) {
    ForkRunning() || ForkWaitingOnLead() || ForkWaitingOnUser() || ForkPausing() || ForkPaused() => true,
    ForkSpawning() || ForkStopping() || ForkMerging() || ForkReported() || ForkDropped() => true,
  },
  (ForkStopping(), ForkMerging() || ForkReported() || ForkDropped()) => true,
  (ForkMerging(), ForkReported() || ForkDropped()) => true,
  // Working again after its report.
  (ForkReported(), ForkRunning(followUp: true)) => true,
  _ => false,
};

/// One fork as its lead's session follows it.
final class ForkRecord {
  ForkRecord._(this.callId, this.title, this.delivery);

  /// The call that started it (`run_subagent`'s id, or `mf-…` for a host fork).
  final String callId;
  String title;
  ForkDelivery delivery;

  /// Its child session, once it started.
  String? childId;
  ForkState state = const ForkSpawning();

  /// Every question it asked, as routed (the newest last).
  final asks = <AskRoute>[];

  /// Reports it gave (a follow-up after the first says so).
  var reports = 0;

  /// The status of its last report, for check_forks.
  SubagentStatus? get reportedAs => switch (state) {
    ForkReported(:final status) => status,
    _ => null,
  };

  AskRoute? askOf(String questionId) => asks.where((a) => a.questionId == questionId).lastOrNull;
}

/// A lead session's forks, by call id: the one record of what each is doing (no loose sets or maps).
final class ForkBook {
  final _records = <String, ForkRecord>{};

  /// Moves that weren't edges of the diagram (a bug), for the tests and the log.
  final refused = <String>[];

  ForkRecord? of(String callId) => _records[callId];

  ForkRecord? byChild(String childId) => _records.values.where((r) => r.childId == childId).firstOrNull;

  Iterable<ForkRecord> get all => _records.values;

  /// Forks at work: starting, running, waiting, paused, stopping or merging.
  Iterable<ForkRecord> get live => _records.values.where((r) => r.state.live);

  /// Live forks with a child session, by call id (what the old `_childOf` held).
  Map<String, String> get children => {for (final r in live) r.callId: ?r.childId};

  /// Live forks whose report goes to the lead as a notification.
  Iterable<ForkRecord> get background => live.where((r) => r.delivery == ForkDelivery.notification);

  Iterable<ForkRecord> get spawning => _records.values.where((r) => r.state is ForkSpawning);

  /// Forks that reported, oldest first.
  Iterable<ForkRecord> get reported => _records.values.where((r) => r.state is ForkReported);

  /// Whether a fork waits on the user (an approval or consent).
  bool get anyWaitingOnUser => _records.values.any((r) => r.state is ForkWaitingOnUser);

  /// A new fork for [callId] (a retry keeps its record and goes back to spawning).
  ForkRecord spawn(String callId, {required String title, ForkDelivery delivery = ForkDelivery.notification}) {
    final r = _records[callId];
    if (r != null && r.state.working) {
      to(callId, const ForkSpawning());
      return r;
    }
    return _records[callId] = ForkRecord._(callId, title, delivery);
  }

  /// Its child [childId] started (or was found again after a restart, [state] taken as running).
  void started(String callId, String childId, {String? title, ForkDelivery? delivery}) {
    final r = _records[callId] ??= ForkRecord._(callId, title ?? '', delivery ?? ForkDelivery.notification);
    r.childId = childId;
    if (title != null && title.isNotEmpty) r.title = title;
    if (delivery != null) r.delivery = delivery;
    if (r.state is ForkSpawning) to(callId, const ForkRunning());
  }

  /// Moves [callId] to [next] along an edge, or records the refused move and stays.
  bool to(String callId, ForkState next) {
    final r = _records[callId];
    if (r == null) return false;
    // The same state again is no move (a waiting-on-lead with another question is: it names the new ask).
    if (r.state.name == next.name && next is! ForkWaitingOnLead) return true;
    if (!forkEdge(r.state, next)) {
      final edge = '$callId: ${r.state} → $next';
      refused.add(edge);
      assert(false, 'Refused fork transition: $edge');
      return false;
    }
    r.state = next;
    if (next is ForkReported) r.reports++;
    return true;
  }

  /// Fork [callId]'s question [questionId] goes to the lead; false when it already went.
  bool askLead(String callId, String questionId) {
    final r = _records[callId];
    if (r == null || r.askOf(questionId) != null) return false;
    final ask = AskToLead(questionId);
    r.asks.add(ask);
    if (r.state.working) to(callId, ForkWaitingOnLead(ask));
    return true;
  }

  /// [questionId] was answered: by the user first ([byUser]), else by the lead. False when it never went to it.
  bool answered(String questionId, {required bool byUser}) {
    for (final r in _records.values) {
      final i = r.asks.indexWhere((a) => a.questionId == questionId);
      if (i < 0) continue;
      if (r.asks[i] is! AskToLead) return false;
      r.asks[i] = byUser ? AskAnsweredByUser(questionId) : AskAnsweredByLead(questionId);
      return true;
    }
    return false;
  }

  /// Whether question [questionId] went to the lead.
  bool askedLead(String questionId) => _records.values.any((r) => r.askOf(questionId) != null);

  /// Stop all: every fork still at work ends with nothing more for the lead. Returns their child ids.
  List<String> dropLive(String why) {
    final kids = <String>[];
    for (final r in [...live]) {
      if (r.childId case final c?) kids.add(c);
      to(r.callId, ForkDropped(why));
    }
    return kids;
  }
}
