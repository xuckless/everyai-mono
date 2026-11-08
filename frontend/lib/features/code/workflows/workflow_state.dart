// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

// A workflow run's lifecycle, the one source of truth for the engine, the host, the journal and the card:
//
//   starting ──script up──▶ running(phase) ──phase()──▶ running(next phase)
//      │                       │  ▲
//      │                       │  └──Resume── pausing / paused ◀──Pause── running (each agent ends its step, then
//      │                       │              pausing ──every agent holds──▶ paused        holds; new agents wait)
//      │                       │
//      │                       ├──Stop / out of time (also while paused)──▶ stopping(outcome) ──script gone──▶ ┐
//      │                       └──the script ended (done() or not)───────────────────────────────────────────▶ ├─▶ shuttingDown(step 1…N)
//      ├──Stop─────────────────────────────────────────▶ stopping(outcome)                                      │
//      └──the script couldn't start─────────────────────────────────────────────────────────────────────────────┘
//                                                                                                   ▼
//                                                                                   ended(done | failed | capped | stopped)
//
//   any state before shuttingDown ──the session closed──▶ detached (the children keep working; the journal stays,
//                                                          and the next launch resumes the run)
//
// Every run ends through the same [ShutdownStep]s, in order, whatever the outcome. A step that fails or runs past its
// time is logged and the next one runs: a run can't be left half shut down.

/// How a run ended.
enum WorkflowOutcome { done, failed, capped, stopped }

/// What a run in some state is waiting on: what the card says and what a stall check reads.
enum RunWaitsOn { nothing, script, agents, shutdown }

/// The steps every run's end goes through, in this order.
enum ShutdownStep {
  /// The script is killed: no more agent() calls.
  script,

  /// Agent calls still going (the script didn't wait for them, or the run was stopped) are stopped, and each one
  /// settles before the next step.
  agents,

  /// What each agent left running ends: its turn, shells and monitors, browsers, app runs, language and MCP
  /// servers, devices. The lead's own stay.
  children,

  /// The end is written to the journal: a resume won't run this again.
  journal,

  /// The lead hears how the run ended (also when the user stopped it), unless Stop all ended it.
  lead,

  /// The session goes back to no workflow, and the run's bookkeeping is dropped.
  workflow,
}

/// A run's state. See the diagram at the top of this file.
@immutable
sealed class RunState {
  const RunState();

  RunWaitsOn get waitsOn;

  /// Whether the run still takes new agent() calls.
  bool get acceptsAgents => false;

  /// Whether the run has not reached its end (and the session's slot is still taken).
  bool get live => true;

  String get name;

  @override
  String toString() => name;
}

final class RunStarting extends RunState {
  const RunStarting();
  @override
  RunWaitsOn get waitsOn => RunWaitsOn.script;
  @override
  String get name => 'starting';
}

final class RunRunning extends RunState {
  const RunRunning([this.phase = '']);

  /// The script's current phase('…'); empty before its first.
  final String phase;
  @override
  RunWaitsOn get waitsOn => RunWaitsOn.agents;
  @override
  bool get acceptsAgents => true;
  @override
  String get name => 'running';
  @override
  bool operator ==(Object other) => other is RunRunning && other.phase == phase;
  @override
  int get hashCode => phase.hashCode;
}

/// Pause: each live agent ends its step and holds; agent() calls wait to start. Time still counts toward the cap.
final class RunPausing extends RunState {
  const RunPausing([this.phase = '']);
  final String phase;
  @override
  RunWaitsOn get waitsOn => RunWaitsOn.agents;
  @override
  bool get acceptsAgents => true;
  @override
  String get name => 'pausing';
}

/// Every live agent holds; Resume goes on where it was.
final class RunPaused extends RunState {
  const RunPaused([this.phase = '']);
  final String phase;
  @override
  RunWaitsOn get waitsOn => RunWaitsOn.nothing;
  @override
  bool get acceptsAgents => true;
  @override
  String get name => 'paused';
}

/// Stopped by the user or a cap: no new agents, and the script is being killed.
final class RunStopping extends RunState {
  const RunStopping(this.outcome, this.why);
  final WorkflowOutcome outcome;
  final String why;
  @override
  RunWaitsOn get waitsOn => RunWaitsOn.script;
  @override
  String get name => 'stopping';
}

final class RunShuttingDown extends RunState {
  const RunShuttingDown(this.step, this.outcome);
  final ShutdownStep step;
  final WorkflowOutcome outcome;

  /// Step [index] (from 1) of [total], for the card.
  int get index => step.index + 1;
  static int get total => ShutdownStep.values.length;
  @override
  RunWaitsOn get waitsOn => RunWaitsOn.shutdown;
  @override
  String get name => 'shuttingDown(${step.name})';
  @override
  bool operator ==(Object other) => other is RunShuttingDown && other.step == step && other.outcome == outcome;
  @override
  int get hashCode => Object.hash(step, outcome);
}

final class RunEnded extends RunState {
  const RunEnded(this.outcome);
  final WorkflowOutcome outcome;
  @override
  RunWaitsOn get waitsOn => RunWaitsOn.nothing;
  @override
  bool get live => false;
  @override
  String get name => 'ended(${outcome.name})';
  @override
  bool operator ==(Object other) => other is RunEnded && other.outcome == outcome;
  @override
  int get hashCode => outcome.hashCode;
}

/// The session closed mid-run: the script is gone, its children work on, and the journal resumes the run.
final class RunDetached extends RunState {
  const RunDetached();
  @override
  RunWaitsOn get waitsOn => RunWaitsOn.nothing;
  @override
  bool get live => false;
  @override
  String get name => 'detached';
}

/// Whether [from] → [to] is an edge of the diagram.
bool runEdge(RunState from, RunState to) => switch ((from, to)) {
  (RunStarting(), RunRunning() || RunStopping() || RunDetached()) => true,
  (RunStarting(), RunShuttingDown(step: ShutdownStep.script)) => true,
  (RunRunning(), RunRunning() || RunStopping() || RunDetached()) => true,
  (RunRunning(), RunShuttingDown(step: ShutdownStep.script)) => true,
  (RunRunning(), RunPausing()) => true,
  // phase() while paused: the phase moves on, the hold stays.
  (RunPausing(), RunPausing()) || (RunPaused(), RunPaused()) => true,
  (RunPausing(), RunPaused() || RunRunning() || RunStopping() || RunDetached()) => true,
  (RunPaused(), RunRunning() || RunStopping() || RunDetached()) => true,
  // The script may end while paused (it waited on nothing): the shutdown runs.
  (RunPausing() || RunPaused(), RunShuttingDown(step: ShutdownStep.script)) => true,
  (RunStopping(), RunDetached()) => true,
  (RunStopping(:final outcome), RunShuttingDown(step: ShutdownStep.script, outcome: final o)) => o == outcome,
  // One step after another, with the outcome kept.
  (RunShuttingDown(:final step, :final outcome), RunShuttingDown(step: final next, outcome: final o)) =>
    o == outcome && next.index == step.index + 1,
  (RunShuttingDown(step: ShutdownStep.workflow, :final outcome), RunEnded(outcome: final o)) => o == outcome,
  _ => false,
};

/// Moves along an edge of the diagram, or reports the move and stays: [onRefused] gets the refused edge. A wrong
/// move is a bug in the caller, so debug builds assert.
RunState runTransition(RunState from, RunState to, {void Function(String edge)? onRefused}) {
  if (runEdge(from, to)) return to;
  final edge = '$from → $to';
  onRefused?.call(edge);
  assert(false, 'Refused workflow run transition: $edge');
  return from;
}

/// What a session's one workflow slot holds (one run at a time, so an agent can't multiply the caps):
///
///   free ──run_workflow call──▶ reserved ──its run starts──▶ running(runId) ──the run ended──▶ free
///     │                            └──it didn't start──────────────────────────────────────▶ free
///     └──Bug fix needs the user's report──▶ askingBug ──answered: the run starts──▶ running(runId)
///                                              └──no report, rewound, stopped──────────────▶ free
@immutable
sealed class RunSlot {
  const RunSlot();
}

final class SlotFree extends RunSlot {
  const SlotFree();
}

/// A run_workflow call is starting a run.
final class SlotReserved extends RunSlot {
  const SlotReserved();
}

/// Bug fix waits for the user to answer its card before its run starts.
final class SlotAskingBug extends RunSlot {
  const SlotAskingBug();
}

final class SlotRunning extends RunSlot {
  const SlotRunning(this.runId);
  final String runId;
}

/// Why a new run can't take [slot], or null when it is free.
String? slotBusyText(RunSlot slot) => switch (slot) {
  SlotFree() => null,
  SlotAskingBug() =>
    'Bug fix is waiting for the user to answer its card in the app. Wait for its <workflow-result> before starting '
        'another workflow.',
  SlotReserved() =>
    'a workflow is already starting in this session. Wait for its <workflow-result> before starting '
        'another.',
  SlotRunning(:final runId) =>
    'a workflow is already running in this session (run $runId). Wait for its <workflow-result> before starting '
        'another.',
};
