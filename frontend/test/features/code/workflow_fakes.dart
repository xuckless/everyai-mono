// Fakes for the workflow engine: a bridge the test plays the script on, a
// launcher whose children answer from a callback, and timers fired by hand.

import 'dart:async';

import 'package:every_ai/features/code/domain/plan_batches.dart';
import 'package:every_ai/features/code/workflows/workflow_bridge.dart';
import 'package:every_ai/features/code/workflows/workflow_engine.dart';

/// The script side of a run: [agent] calls as a script would, [finish] ends it.
final class FakeBridge implements WorkflowBridge {
  final _requests = StreamController<Map<String, Object?>>();
  final _output = StreamController<String>();
  final _exit = Completer<int>();
  final _waiting = <Object?, Completer<Object?>>{};
  var _id = 0;
  var killed = false;

  @override
  Stream<Map<String, Object?>> get requests => _requests.stream;
  @override
  Stream<String> get output => _output.stream;
  @override
  Future<int> get exit => _exit.future;

  /// agent(prompt, opts) as the script calls it: the reply, or the error thrown.
  Future<Object?> agent(String prompt, [Map<String, Object?> opts = const {}]) {
    final id = ++_id;
    final c = _waiting[id] = Completer<Object?>();
    _requests.add({
      'id': id,
      'fn': 'agent',
      'args': {...opts, 'prompt': prompt},
    });
    return c.future;
  }

  void note(String fn, Map<String, Object?> args) => _requests.add({'fn': fn, 'args': args});

  @override
  void reply(Object? id, {Object? result, String? error}) {
    final c = _waiting.remove(id);
    if (c == null || c.isCompleted) return;
    error != null ? c.completeError(error) : c.complete(result);
  }

  /// The script returned [result] and exited.
  void finish(Object? result) {
    note('done', {'result': result});
    _end(0);
  }

  void _end(int code) {
    if (_exit.isCompleted) return;
    unawaited(_requests.close());
    unawaited(_output.close());
    _exit.complete(code);
  }

  @override
  void kill() {
    killed = true;
    _end(137);
  }
}

/// Children that reply with [reply] (turn 1 is the brief, 2 a repair).
final class FakeLauncher implements AgentLauncher {
  final started = <({String prompt, String key, String brief, String childId})>[];
  final calls = <WorkflowAgentCall>[];
  final watched = <String>[];
  final followUps = <(String, String)>[];
  final stopped = <String>[];
  final finished = <(String, bool)>[];
  final _calls = <String, WorkflowAgentCall>{};
  final _turns = <String, int>{};
  var _n = 0;
  var _active = 0;
  var maxActive = 0;

  String Function(WorkflowAgentCall call, int turn) reply = (call, turn) => 'ok:${call.prompt}';

  /// Holds a child's turn until the future completes.
  Future<void> Function(WorkflowAgentCall call)? gate;

  /// What the child has cost EveryAI (null: an outside harness).
  int? Function(WorkflowAgentCall call) spent = (call) => null;

  /// Calls the journal knew before this launcher existed, by child id.
  final known = <String, WorkflowAgentCall>{};

  /// The app's bug_check record for a child (see [AgentLauncher.bugCheckOf]).
  Map<String, Object?> Function(String childId) bugCheck = (id) => {'available': true, 'state': 'verified'};
  final bugChecked = <String>[];

  /// The verdict of a child's batch check (see [AgentLauncher.batchCheckOf]); it may hold.
  Future<Map<String, Object?>> Function(String childId, PlanBatch batch) batchCheck = (id, b) async => {'passed': true};
  final batchChecked = <(String, String)>[];

  /// What [finish] returns (the merge note).
  String? Function(String childId, bool ok) finishNote = (id, ok) => null;

  /// Holds a child's start until the future completes (a slow harness or worktree).
  Future<void> Function(WorkflowAgentCall call)? startGate;

  @override
  Future<WorkflowChild> start(WorkflowAgentCall call) async {
    await startGate?.call(call);
    final id = 'child-${++_n}-${call.prompt}';
    _calls[id] = call;
    calls.add(call);
    started.add((prompt: call.prompt, key: call.key, brief: call.brief, childId: id));
    return (childId: id, harness: call.harness ?? 'lead', model: call.model ?? 'm', note: null);
  }

  Future<WorkflowAgentResult> _turn(String childId) async {
    final call = _calls[childId] ?? WorkflowAgentCall(key: '', prompt: childId.split('-').last, label: '', phase: '');
    final turn = _turns[childId] = (_turns[childId] ?? 0) + 1;
    _active++;
    if (_active > maxActive) maxActive = _active;
    // A stop ends the turn being watched, as the app's launcher does.
    final stop = _stops[childId] = Completer<void>();
    try {
      final held = gate?.call(call);
      if (held != null) {
        var stoppedFirst = false;
        await Future.any([held, stop.future.then((_) => stoppedFirst = true)]);
        if (stoppedFirst) return (text: '', error: 'Stopped.', spentMicros: spent(call));
      }
      return (text: reply(call, turn), error: null, spentMicros: spent(call));
    } on Object catch (e) {
      return (text: '', error: '$e', spentMicros: spent(call));
    } finally {
      _active--;
      if (_stops[childId] == stop) _stops.remove(childId);
    }
  }

  final _stops = <String, Completer<void>>{};

  /// Children watched as reattached (started before a restart).
  final reattached = <String>[];

  @override
  Future<WorkflowAgentResult> watch(String childId, {bool reattached = false}) {
    watched.add(childId);
    if (reattached) this.reattached.add(childId);
    return _turn(childId);
  }

  @override
  Future<WorkflowAgentResult> followUp(String childId, String text) {
    followUps.add((childId, text));
    return _turn(childId);
  }

  @override
  Future<String?> finish(String childId, {required bool ok}) async {
    finished.add((childId, ok));
    return finishNote(childId, ok);
  }

  @override
  Future<Map<String, Object?>> batchCheckOf(String childId, PlanBatch batch) {
    batchChecked.add((childId, batch.id));
    return batchCheck(childId, batch);
  }

  @override
  Future<Map<String, Object?>> bugCheckOf(String childId) async {
    bugChecked.add(childId);
    return bugCheck(childId);
  }

  @override
  void stop(String childId) {
    stopped.add(childId);
    final c = _stops.remove(childId);
    if (c != null && !c.isCompleted) c.complete();
  }

  final paused = <String>[];
  final resumed = <String>[];

  @override
  Future<void> pause(String childId) async => paused.add(childId);

  @override
  Future<void> resume(String childId) async => resumed.add(childId);

  /// Each child's last progress; tests set it to make a run stall.
  final activity = <String, DateTime>{};
  @override
  DateTime? lastActivity(String childId) => activity[childId];

  final restarted = <(String, String)>[];
  @override
  Future<void> restart(String childId, String note) async => restarted.add((childId, note));

  final messages = <(String, String)>[];
  @override
  Future<bool> message(String childId, String text) async {
    messages.add((childId, text));
    return true;
  }

  /// Children released at the run's end, in order.
  final released = <String>[];

  @override
  Future<void> release(String childId) async => released.add(childId);
}

/// Timers that fire only when the test says so.
final class FakeTimers {
  final durations = <Duration>[];
  final _callbacks = <void Function()>[];

  Timer call(Duration d, void Function() cb) {
    durations.add(d);
    _callbacks.add(cb);
    return _FakeTimer();
  }

  void fire() {
    for (final cb in [..._callbacks]) {
      cb();
    }
  }
}

final class _FakeTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => false;
  @override
  int get tick => 0;
}
