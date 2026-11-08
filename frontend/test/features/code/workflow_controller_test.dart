import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/code_settings_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/permissions.dart' show ApprovalScope, Verdict;
import 'package:every_ai/features/code/drivers/acp/acp_mapping.dart' show agentMessageEvent;
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/git/git_service.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/workflows/workflow_agents_tool.dart';
import 'package:every_ai/features/code/harness/harness.dart' show NativeMode;
import 'package:every_ai/features/code/host/host.dart';
import 'package:every_ai/features/code/host/host_prompts.dart';
import 'package:every_ai/features/code/host/host_providers.dart';
import 'package:every_ai/features/code/workflows/workflow_engine.dart';
import 'package:every_ai/features/code/workflows/workflow_estimate.dart';
import 'package:every_ai/features/code/workflows/workflow_proposal.dart';
import 'package:every_ai/features/code/workflows/workflow_landing.dart';
import 'package:every_ai/features/code/domain/subagents.dart' show endWorkflowTool;
import 'package:every_ai/features/code/workflows/workflow_library.dart' show loadBundledWorkflows;
import 'package:every_ai/features/code/workflows/workflow_notes.dart' show maxWorkflowId;
import 'package:every_ai/features/code/workflows/workflow_picker.dart' show WorkflowPick;
import 'package:every_ai/features/code/workflows/workflow_runs.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../support/fake_leads.dart';
import 'workflow_fakes.dart';

// A workflow run from a session's controller: its agents are child
// sessions on whichever harness each call names.

/// A keychain that keeps nothing.
final class _NoStore implements SecretStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Directory tmp;
  late Directory project;
  late FakeLeadSession lead;
  late Map<String, FakeLeadDriver> drivers;
  late ProviderContainer container;
  late FakeBridge bridge;
  late Map<String, UsageTotals> usage;
  late Preferences prefs;
  Map<String, Object?>? startedArgs;
  String? startedSource;
  late FakeHost host;

  /// The backend: every request's path, and what it answers (no network by default).
  late List<String> api;
  late Future<http.Response> Function(http.Request req) backend;

  Future<void> git(List<String> args) async {
    final r = await Process.run('git', args, workingDirectory: project.path);
    if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
  }

  /// The app on the same database, drivers and data folder: a second one is a restart.
  ProviderContainer makeContainer() => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(prefs),
      modelCatalogProvider.overrideWith(FixedCatalog.new),
      codeUsageProvider.overrideWithBuild((ref, n) async => usage[n.sessionId] ?? UsageTotals.zero),
      driverRegistryProvider.overrideWithValue(DriverRegistry({...drivers})),
      hostServerProvider.overrideWithValue(host),
      driverDataDirProvider.overrideWithValue(() async => '${tmp.path}/data'),
      apiClientProvider.overrideWithValue(
        ApiClient(
          baseUrl: Uri.parse('http://backend/'),
          client: MockClient((req) async {
            api.add(req.url.path);
            return backend(req);
          }),
        ),
      ),
      codeSideModelProvider.overrideWithValue((messages) async => ''),
      gatewayKeysProvider.overrideWith((ref) => GatewayKeys(store: _NoStore(), mint: () async => 'sk-eai-test')),
      workflowBridgeProvider.overrideWithValue(({required dir, required source, required args}) async {
        startedArgs = args;
        startedSource = source;
        return bridge;
      }),
    ],
  );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('workflow-controller');
    project = await Directory('${tmp.path}/project').create();
    lead = FakeLeadSession();
    bridge = FakeBridge();
    usage = {};
    drivers = {
      'test': FakeLeadDriver('test', session: lead),
      'fake2': FakeLeadDriver('fake2', label: 'Second CLI'),
      'cli': FakeLeadDriver('cli', needsConsent: true, label: 'Gated CLI'),
    };
    prefs = await Preferences.load(db);
    host = FakeHost();
    startedArgs = null;
    api = [];
    backend = (req) async => http.Response('no network in this test', 599);
    prefs['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'P', path: project.path).toJson()]);
    container = makeContainer();
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    // A last write of the app's (an estimate's file) may still be landing.
    for (var i = 0; ; i++) {
      try {
        await tmp.delete(recursive: true);
        break;
      } on FileSystemException {
        if (i == 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  });

  Future<CodeSessionController> open({String harness = 'test'}) async {
    final info = await container
        .read(codeSessionsProvider.notifier)
        .start(
          project: container.read(codeProjectsProvider).single,
          prompt: 'Lead the work',
          model: '',
          mode: AgentMode.autoEdit,
          harness: harness,
        );
    container.listen(codeSessionProvider(info.id), (_, _) {});
    await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
    return container.read(codeSessionProvider(info.id).notifier);
  }

  /// The nonce the lead's briefing names, and a workflow result as the lead is sent it.
  String leadNonce() =>
      RegExp('Notice nonce: `([0-9a-f]{32})`').firstMatch(drivers['test']!.specs.first.briefing!.sessionSkill!)![1]!;

  String signed(String runId, String body) =>
      '<everyai-notice kind="workflow-result" id="$runId" nonce="${leadNonce()}">\n$body';

  Future<CodeSessionInfo> child() => whenValue(
    container,
    codeSessionsProvider,
    (List<CodeSessionInfo> all) => all.any((s) => s.parentCallId.startsWith('wf-')),
  ).then((all) => all.firstWhere((s) => s.parentCallId.startsWith('wf-')));

  /// The child's agent answers [text] and ends its turn.
  void answer(FakeLeadSession s, String text) => s
    ..add(stateEvent('${s.id}-r', ExecutionStatus.running))
    ..add(agentMessageEvent('${s.id}-m', text))
    ..add(stateEvent('${s.id}-f', ExecutionStatus.finished));

  test('an agent on another harness is a child session there, and the result goes to the lead', () async {
    final c = await open();
    final runId = await c.runWorkflow('demo', 'source', args: {'n': 1});
    final reply = bridge.agent('Fix the bug', {'harness': 'fake2', 'label': 'Fixer'});
    final info = await child();
    expect(info.harness, 'fake2');
    expect(info.parentId, c.sessionId);
    expect(info.parentCallId, startsWith('wf-$runId-'));
    expect(info.title, 'Fixer');
    final s = drivers['fake2']!.latest!;
    expect(s.sent.single, contains('Fix the bug'));
    answer(s, 'Fixed it');
    expect(await reply, 'Fixed it');
    bridge.finish({'fixed': true});
    final runs = await whenValue(
      container,
      workflowRunsProvider(c.sessionId),
      (List<WorkflowRun> r) => r.isNotEmpty && r.single.status == WorkflowStatus.done,
    );
    expect(runs.single.agents.single.harness, 'fake2');
    await pumpEventQueue();
    expect(lead.sent.last, startsWith(signed(runId, '<workflow-result name="demo" status="done">')));
    expect(lead.sent.last, endsWith('\n</everyai-notice>'));
    expect(lead.sent.last, contains('"fixed":true'));
    // An ended run's journal is kept aside, so opening the session doesn't read it again.
    final dir = '${tmp.path}/data/workflows/${c.sessionId}';
    expect(File('$dir/$runId.done.jsonl').existsSync(), isTrue);
    expect(File('$dir/$runId.jsonl').existsSync(), isFalse);
  });

  test('a stalled run: the lead hears first and acts with workflow_agents; then the user', () async {
    CodeSessionController.workflowStallAfter = Duration.zero;
    addTearDown(() => CodeSessionController.workflowStallAfter = const Duration(minutes: 7));
    final c = await open();
    final runId = await c.runWorkflow('demo', 'source', args: {'n': 1});
    final reply = bridge.agent('Fix the bug', {'harness': 'fake2', 'label': 'Fixer'});
    final kid = await child();
    await whenValue(container, codeSessionProvider(kid.id).select((s) => s.connected), (bool b) => b);
    HostCall agents(Map<String, Object?> args) =>
        HostCall(id: 'wa', sessionId: '', name: workflowAgentsTool, args: args, ended: Completer<HostEnd>().future);
    final list = await c.call(agents({'action': 'list'}));
    expect(list.text, contains('Fixer (agent '));
    final key = RegExp(r'agent (\S+),').firstMatch(list.text)![1]!;
    final engine = c.workflowEngineOf(runId)!;
    engine.checkStall();
    expect(engine.state, isA<RunStalled>());
    for (var i = 0; i < 50 && !lead.sent.any((m) => m.contains('<workflow-stalled')); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(lead.sent.where((m) => m.contains('<workflow-stalled')).single, contains('- Fixer (agent $key)'));
    expect((await c.call(agents({'action': 'inspect', 'agent': key}))).text, contains('Fixer (agent $key, id'));
    expect((await c.call(agents({'action': 'inspect', 'agent': 'nope'}))).text, contains('No live agent "nope"'));
    expect((await c.call(agents({'action': 'ignore'}))).text, startsWith('Noted'));
    expect(engine.state, isA<RunRunning>());
    // Stalled again, and the lead does nothing: the user decides (the session needs them).
    engine
      ..checkStall()
      ..checkStall();
    expect(engine.state, const RunStalled('', StallStage.userTold));
    await pumpEventQueue();
    expect(container.read(codeSessionProvider(c.sessionId)).status, SessionStatus.needsInput);
    answer(drivers['fake2']!.latest!, 'Fixed it');
    expect(await reply, 'Fixed it');
    bridge.finish(null);
    await pumpEventQueue();
  });

  group('the drift check', () {
    HostCall agents(Map<String, Object?> args) =>
        HostCall(id: 'wa', sessionId: '', name: workflowAgentsTool, args: args, ended: Completer<HostEnd>().future);

    /// A run whose Research phase ends with one agent's answer.
    Future<(CodeSessionController, String)> phaseEnded({String harness = 'test'}) async {
      final c = await open(harness: harness);
      final runId = await c.runWorkflow('demo', 'source', args: {'task': 'Fix the login bug'});
      bridge.note('phase', {'title': 'Research'});
      final reply = bridge.agent('Look', {'harness': 'fake2', 'label': 'Scout'});
      final kid = await child();
      await whenValue(container, codeSessionProvider(kid.id).select((s) => s.connected), (bool b) => b);
      answer(drivers['fake2']!.latest!, 'Rewrote the billing page instead');
      await reply;
      bridge.note('phase', {'title': 'Build'});
      await pumpEventQueue();
      return (c, runId);
    }

    test('an outside lead is asked to compare, and its off_track pauses the run for the user', () async {
      final (c, runId) = await phaseEnded();
      for (var i = 0; i < 50 && !lead.sent.any((m) => m.contains('<workflow-checkpoint')); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final ask = lead.sent.singleWhere((m) => m.contains('<workflow-checkpoint'));
      expect(ask, contains('The Research phase of the demo run ended'));
      expect(ask, contains('Fix the login bug'));
      expect(ask, contains('Scout answered:\nRewrote the billing page instead'));
      expect(api.where((p) => p.contains('decide')), isEmpty, reason: 'EveryAI spends nothing on an outside lead');
      final r = await c.call(agents({'action': 'off_track', 'text': 'It works on billing, not the login bug'}));
      expect(r.text, startsWith('Paused'));
      final engine = c.workflowEngineOf(runId)!;
      await pumpEventQueue();
      expect(engine.state, isA<RunPaused>().having((s) => s.reason, 'reason', PauseReason.offTrack));
      expect(
        engine.snapshot.rows.last.text,
        'Off track: It works on billing, not the login bug. Paused until you decide.',
      );
      expect(container.read(codeSessionProvider(c.sessionId)).status, SessionStatus.needsInput);
      await c.resumeWorkflow(runId);
      expect(engine.state, isA<RunRunning>());
      bridge.finish(null);
      await pumpEventQueue();
    });

    test('an EveryAI lead asks the decider once; only a clear no pauses', () async {
      drivers['everyai'] = FakeLeadDriver('everyai', session: lead);
      container.dispose();
      container = makeContainer();
      var onTrack = false;
      final asked = <Map<String, Object?>>[];
      backend = (req) async {
        if (!req.url.path.endsWith('v1/aux/decide')) return http.Response('no', 599);
        asked.add(jsonDecode(req.body) as Map<String, Object?>);
        return http.Response(
          jsonEncode({
            'answers': [
              {'id': 'on_track', 'value': onTrack},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      };
      final (c, runId) = await phaseEnded(harness: 'everyai');
      final engine = c.workflowEngineOf(runId)!;
      for (var i = 0; i < 50 && engine.state is! RunPaused; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(asked.single['job'], 'drift');
      expect(asked.single['text'], contains('Rewrote the billing page instead'));
      expect(engine.state, isA<RunPaused>().having((s) => s.reason, 'reason', PauseReason.offTrack));
      expect(lead.sent.where((m) => m.contains('<workflow-checkpoint')).single, contains('paused'));
      await c.resumeWorkflow(runId);
      // The next phase is on track: it goes on.
      onTrack = true;
      final scout = drivers['fake2']!.latest;
      final reply = bridge.agent('Build', {'harness': 'fake2', 'label': 'Builder'});
      for (var i = 0; i < 100 && identical(drivers['fake2']!.latest, scout); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final builder = drivers['fake2']!.latest!;
      await whenValue(
        container,
        codeSessionsProvider,
        (List<CodeSessionInfo> all) => all.any((s) => s.title == 'Builder'),
      );
      await pumpEventQueue();
      answer(builder, 'Fixed the login bug');
      await reply;
      bridge.note('phase', {'title': 'Check'});
      for (var i = 0; i < 50 && asked.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await pumpEventQueue();
      expect(asked, hasLength(2));
      expect(engine.state, isA<RunRunning>());
      bridge.finish(null);
      await pumpEventQueue();
    });
  });

  test("workflow_agents restart: the same agent goes on in a new turn, and its call gets that turn's answer", () async {
    final c = await open();
    await c.runWorkflow('demo', 'source', args: {'n': 1});
    final reply = bridge.agent('Fix the bug', {'harness': 'fake2', 'label': 'Fixer'});
    final kid = await child();
    await whenValue(container, codeSessionProvider(kid.id).select((s) => s.connected), (bool b) => b);
    final agent = drivers['fake2']!.latest!;
    agent.add(stateEvent('${agent.id}-r0', ExecutionStatus.running));
    await pumpEventQueue();
    final list = await c.call(
      HostCall(
        id: 'wa',
        sessionId: '',
        name: workflowAgentsTool,
        args: {'action': 'list'},
        ended: Completer<HostEnd>().future,
      ),
    );
    final key = RegExp(r'agent (\S+),').firstMatch(list.text)![1]!;
    var settled = false;
    unawaited(reply.then((_) => settled = true));
    final restarting = c.call(
      HostCall(
        id: 'wb',
        sessionId: '',
        name: workflowAgentsTool,
        args: {'action': 'restart', 'agent': key, 'text': 'use a timeout'},
        ended: Completer<HostEnd>().future,
      ),
    );
    // The stop reaches the agent, and its turn ends; that isn't the agent's answer.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    agent.add(stateEvent('${agent.id}-s', ExecutionStatus.finished));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    agent.add(stateEvent('${agent.id}-r1', ExecutionStatus.running));
    expect((await restarting).text, startsWith('Restarted'));
    expect(agent.sent.any((m) => m.contains('use a timeout')), isTrue, reason: '${agent.sent}');
    expect(settled, isFalse);
    answer(agent, 'Fixed it, with a timeout');
    expect(await reply, 'Fixed it, with a timeout');
    bridge.finish(null);
    await pumpEventQueue();
  });

  HostCall runCall(Map<String, Object?> args) =>
      HostCall(id: 'h1', sessionId: '', name: runWorkflowTool, args: args, ended: Completer<HostEnd>().future);

  /// The estimate card for [c]'s open proposal; Start on it.
  Future<void> start(CodeSessionController c) async {
    expect(container.read(codeSessionProvider(c.sessionId)).proposal, isNotNull, reason: 'no estimate is open');
    expect(await c.startProposal(), isNull);
    await pumpEventQueue();
  }

  test('run_workflow proposes; Start runs it, and its result waits for the lead\'s turn to end', () async {
    final c = await open();
    expect([for (final p in await c.workflowPrompts()) p.id], ['ultra', 'bugfix', 'security_review']);
    var r = await c.call(runCall({'id': 'nope'}));
    expect(r.isError, isTrue);
    expect(r.text, contains('It can run: ultra, bugfix, security_review'));
    r = await c.call(runCall({'id': 'ultra', 'args': 'x'}));
    expect(r.isError, isTrue);

    r = await c.call(
      runCall({
        'id': 'security_review',
        'args': {'base': 'main'},
      }),
    );
    expect(r.isError, isFalse);
    expect(r.text, startsWith('The user now sees an estimate for Security review'));
    // Nothing runs until the user starts it; the session waits on them.
    expect(startedArgs, isNull);
    final card = container.read(codeSessionProvider(c.sessionId)).proposal!;
    expect(card.estimate.agents, (6, 6));
    expect(card.capUsd, isNull, reason: 'an outside lead has no money cap');
    expect(container.read(codeSessionProvider(c.sessionId)).status, SessionStatus.needsInput);
    await start(c);
    expect(container.read(codeSessionProvider(c.sessionId)).proposal, isNull);
    expect(startedSource, contains("id: 'security_review'"));
    expect(startedArgs!['base'], 'main');
    // The script's ctx: the run, the lead, and no review model on an outside lead (it would spend).
    final ctx = startedArgs!['_ctx']! as Map;
    expect(ctx['lead'], {'harness': 'test', 'model': ''});
    expect(ctx['review'], isNull);

    // One run at a time: a second call is refused while this one runs.
    r = await c.call(
      runCall({
        'id': 'bugfix',
        'args': {'bug': 'x'},
      }),
    );
    expect(r.isError, isTrue);
    expect(r.text, contains('already running in this session (run ${ctx['runId']})'));

    // The lead is mid-turn when the run ends: the result goes after it, not into the user's queue.
    final before = lead.sent.length;
    lead.add(stateEvent('busy', ExecutionStatus.running));
    await whenValue(container, codeSessionProvider(c.sessionId).select((s) => s.transcript.running), (bool b) => b);
    bridge.finish({'findings': <Object>[]});
    await pumpEventQueue();
    expect(container.read(codeSessionProvider(c.sessionId)).queued, isEmpty);
    expect(lead.sent.length, before);
    // Stop clears the user's queue; the result stays and goes once the lead is idle.
    await c.stop();
    lead.add(stateEvent('idle', ExecutionStatus.finished));
    for (var i = 0; i < 50 && !lead.sent.any((m) => m.contains('<workflow-result')); i++) {
      await pumpEventQueue();
    }
    expect(lead.sent.where((m) => m.contains('<workflow-result')), hasLength(1));
    expect(
      lead.sent.last,
      startsWith(signed(ctx['runId']! as String, '<workflow-result name="Security review" status="done">')),
    );
    // The run ended, so another may start.
    r = await c.call(
      runCall({
        'id': 'bugfix',
        'args': {'bug': 'x'},
      }),
    );
    expect(r.isError, isFalse);
    expect(container.read(codeSessionProvider(c.sessionId)).proposal!.workflowId, 'bugfix');
  });

  test('a read-only agent of a Full auto lead runs commands but asks before edits', () async {
    final c = await open();
    await c.setMode(AgentMode.fullAuto);
    await c.runWorkflow('demo', 'source');
    unawaited(bridge.agent('Review', {'harness': 'fake2', 'readOnly': true}).catchError((Object _) => null));
    final kid = await child();
    expect(kid.mode, AgentMode.ask);
    container.listen(codeSessionProvider(kid.id), (_, _) {});
    final s = drivers['fake2']!.conversations.values.single;
    s
      ..add(actionEvent(id: 'c1', toolName: 'bash', kind: 'TerminalAction', args: {'command': r'grep -n x $(ls)'}))
      ..add(stateEvent('cw', ExecutionStatus.waitingForConfirmation));
    for (var i = 0; i < 100 && s.answers.isEmpty; i++) {
      await pumpEventQueue();
    }
    expect(s.answers.single.accept, isTrue);
    s
      ..add(
        actionEvent(
          id: 'e1',
          toolName: 'str_replace_editor',
          kind: 'FileEditorAction',
          args: {'command': 'create', 'path': '/tmp/x.dart', 'file_text': 'x'},
        ),
      )
      ..add(stateEvent('ew', ExecutionStatus.waitingForConfirmation));
    await whenValue(
      container,
      codeSessionProvider(kid.id).select((s) => s.transcript.pending.length),
      (int n) => n == 1,
    );
    expect(s.answers, hasLength(1));
    // Out of Full auto it asks before commands again.
    await c.setMode(AgentMode.ask);
    expect(container.read(codeSessionProvider(kid.id).notifier).policy.session, isNot(contains('*')));
  });

  test('agents start in the lead\'s mode, and allowing a call for all forks settles the waiting siblings', () async {
    final c = await open();
    await c.setMode(AgentMode.ask);
    await c.runWorkflow('demo', 'source');
    unawaited(bridge.agent('One', {'harness': 'fake2'}).catchError((Object _) => null));
    unawaited(bridge.agent('Two', {'harness': 'fake2'}).catchError((Object _) => null));
    final kids = await whenValue(
      container,
      codeSessionsProvider,
      (List<CodeSessionInfo> all) => all.where((s) => s.parentCallId.startsWith('wf-')).length == 2,
    ).then((all) => all.where((s) => s.parentCallId.startsWith('wf-')).toList());
    expect(kids.map((k) => k.mode), everyElement(AgentMode.ask));
    final sessions = drivers['fake2']!.conversations.values.toList();
    expect(sessions, hasLength(2));
    for (final k in kids) {
      container.listen(codeSessionProvider(k.id), (_, _) {});
    }
    // Both ask to run the same command.
    for (final (i, s) in sessions.indexed) {
      s
        ..add(actionEvent(id: 'a$i', toolName: 'bash', kind: 'TerminalAction', args: {'command': 'npm test'}))
        ..add(stateEvent('w$i', ExecutionStatus.waitingForConfirmation));
    }
    for (final k in kids) {
      await whenValue(
        container,
        codeSessionProvider(k.id).select((s) => s.transcript.pending.length),
        (int n) => n == 1,
      );
    }
    expect(sessions.map((s) => s.answers), everyElement(isEmpty));
    final first = container.read(codeSessionProvider(kids.first.id).notifier);
    expect(first.askReasons().values.single, 'Ask mode asks before every edit and command.');
    // Which kid owns which conversation: the one the first controller answers.
    await first.approve(ApprovalScope.session);
    await pumpEventQueue();
    expect(sessions.map((s) => s.answers.map((a) => a.accept).toList()), everyElement([true]));
    // Remembered in the lead's session scope, so the lead's own call runs too.
    expect(c.policy.session, contains('npm test *'));
  });

  test("a read-only agent neither uses nor adds to the lead's session approvals", () async {
    final c = await open();
    await c.setMode(AgentMode.ask);
    lead
      ..add(actionEvent(id: 'l1', toolName: 'bash', kind: 'TerminalAction', args: {'command': 'npm test'}))
      ..add(stateEvent('lw', ExecutionStatus.waitingForConfirmation));
    await whenValue(
      container,
      codeSessionProvider(c.sessionId).select((s) => s.transcript.pending.length),
      (int n) => n == 1,
    );
    await c.approve(ApprovalScope.session);
    expect(c.policy.session, contains('npm test *'));
    await c.runWorkflow('demo', 'source');
    unawaited(bridge.agent('Review', {'harness': 'fake2', 'readOnly': true}).catchError((Object _) => null));
    final kid = await child();
    expect(kid.ownApprovals, isTrue);
    expect(kid.sharesApprovals, isFalse);
    container.listen(codeSessionProvider(kid.id), (_, _) {});
    final reviewer = container.read(codeSessionProvider(kid.id).notifier);
    expect(reviewer.policy.session, isNot(contains('npm test *')));
    final s = drivers['fake2']!.conversations.values.single;
    s
      ..add(actionEvent(id: 'r1', toolName: 'bash', kind: 'TerminalAction', args: {'command': 'npm test'}))
      ..add(stateEvent('rw', ExecutionStatus.waitingForConfirmation));
    await whenValue(
      container,
      codeSessionProvider(kid.id).select((s) => s.transcript.pending.length),
      (int n) => n == 1,
    );
    expect(s.answers, isEmpty);
    // Its own "for this session" stays its own.
    s
      ..add(actionEvent(id: 'r2', toolName: 'bash', kind: 'TerminalAction', args: {'command': 'make lint'}))
      ..add(stateEvent('rw2', ExecutionStatus.waitingForConfirmation));
    await reviewer.approve(ApprovalScope.session);
    expect(reviewer.policy.session, isNotEmpty);
    expect(c.policy.session, isNot(contains('make lint *')));
  });

  test("allowing on one read-only agent's card settles its read-only siblings, not the lead", () async {
    final c = await open();
    await c.setMode(AgentMode.ask);
    await c.runWorkflow('demo', 'source');
    for (final l in ['lens:a', 'lens:b']) {
      unawaited(bridge.agent(l, {'harness': 'fake2', 'readOnly': true}).catchError((Object _) => null));
    }
    final kids = await whenValue(
      container,
      codeSessionsProvider,
      (List<CodeSessionInfo> all) => all.where((s) => s.parentCallId.startsWith('wf-')).length == 2,
    ).then((all) => all.where((s) => s.parentCallId.startsWith('wf-')).toList());
    for (final k in kids) {
      container.listen(codeSessionProvider(k.id), (_, _) {});
    }
    final sessions = drivers['fake2']!.conversations.values.toList();
    for (final (i, s) in sessions.indexed) {
      s
        ..add(actionEvent(id: 'g$i', toolName: 'bash', kind: 'TerminalAction', args: {'command': 'grep -rn x \$(ls)'}))
        ..add(stateEvent('gw$i', ExecutionStatus.waitingForConfirmation));
    }
    for (final k in kids) {
      await whenValue(
        container,
        codeSessionProvider(k.id).select((s) => s.transcript.pending.length),
        (int n) => n == 1,
      );
    }
    expect(sessions.map((s) => s.answers), everyElement(isEmpty));
    // The card's "Allow all commands for this session".
    await container.read(codeSessionProvider(kids.first.id).notifier).approve(ApprovalScope.sessionAll);
    await pumpEventQueue();
    expect(sessions.map((s) => s.answers.map((a) => a.accept).toList()), everyElement([true]));
    // The lead's own approvals didn't grow.
    expect(c.policy.session, isEmpty);
  });

  test("a user's no tells the agent why the app asked", () async {
    final c = await open();
    await c.setMode(AgentMode.ask);
    lead
      ..add(actionEvent(id: 'x1', toolName: 'bash', kind: 'TerminalAction', args: {'command': 'npm test'}))
      ..add(stateEvent('xw', ExecutionStatus.waitingForConfirmation));
    await whenValue(
      container,
      codeSessionProvider(c.sessionId).select((s) => s.transcript.pending.length),
      (int n) => n == 1,
    );
    await c.deny('use yarn');
    final reason = lead.answers.last.reason!;
    expect(reason, contains("It needed the user's OK because: Ask mode asks before every edit and command."));
    expect(reason, endsWith('use yarn'));
  });

  group('native modes', () {
    const ask = NativeMode(id: 'default', label: 'Default', policy: AgentMode.ask);
    const edits = NativeMode(id: 'acceptEdits', label: 'Accept edits', policy: AgentMode.autoEdit);
    const auto = NativeMode(id: 'auto', label: 'Auto', policy: AgentMode.fullAuto);

    Future<CodeSessionController> openOn(String harness, AgentMode mode) async {
      final info = await container
          .read(codeSessionsProvider.notifier)
          .start(
            project: container.read(codeProjectsProvider).single,
            prompt: 'Lead the work',
            model: '',
            mode: mode,
            harness: harness,
          );
      container.listen(codeSessionProvider(info.id), (_, _) {});
      await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
      // The mode feed's listener is on before the test sets modes.
      await pumpEventQueue();
      return container.read(codeSessionProvider(info.id).notifier);
    }

    test('a Full auto session whose first list lacks auto moves there once a later list has it', () async {
      final c = await openOn('fake2', AgentMode.fullAuto);
      final s = drivers['fake2']!.latest!;
      s.modeFeed.set(modes: [ask, edits], current: 'default');
      await pumpEventQueue();
      expect(s.picked, ['acceptEdits']);
      s.modeFeed.set(modes: [ask, edits, auto]);
      await pumpEventQueue();
      expect(s.picked, ['acceptEdits', 'auto']);
      expect(container.read(codeSessionProvider(c.sessionId)).mode, AgentMode.fullAuto);
      // Once there, nothing more moves it.
      s.modeFeed.set(modes: [ask, edits, auto]);
      await pumpEventQueue();
      expect(s.picked, hasLength(2));
    });

    test('a mode the user picks meanwhile wins over the one the session started in', () async {
      final c = await openOn('fake2', AgentMode.fullAuto);
      final s = drivers['fake2']!.latest!;
      s.modeFeed.set(modes: [ask, edits], current: 'default');
      await pumpEventQueue();
      await c.setNativeMode('default');
      s.modeFeed.set(modes: [ask, edits, auto]);
      await pumpEventQueue();
      expect(s.picked, ['acceptEdits', 'default']);
    });

    test("an agent in the lead's mode gets its native mode too; a read-only one doesn't", () async {
      final c = await openOn('fake2', AgentMode.fullAuto);
      final s = drivers['fake2']!.latest!;
      s.modeFeed.set(modes: [ask, edits, auto], current: 'default');
      await pumpEventQueue();
      expect(container.read(codeSessionsProvider.notifier).byId(c.sessionId)!.nativeMode, 'auto');
      await c.runWorkflow('demo', 'source');
      unawaited(bridge.agent('Review', {'harness': 'fake2', 'readOnly': true}).catchError((Object _) => null));
      final reviewer = await child();
      expect((reviewer.mode, reviewer.nativeMode), (AgentMode.ask, ''));
      container.listen(codeSessionProvider(reviewer.id), (_, _) {});
      await pumpEventQueue();
      final rs = drivers['fake2']!.latest!;
      rs.modeFeed.set(modes: [ask, edits, auto], current: 'default');
      await pumpEventQueue();
      expect(rs.picked, isEmpty);
      unawaited(bridge.agent('Fix', {'harness': 'fake2'}).catchError((Object _) => null));
      final fixer = await whenValue(
        container,
        codeSessionsProvider,
        (List<CodeSessionInfo> all) => all.any((k) => k.title == 'Fix' || (k.parentId != null && k.id != reviewer.id)),
      ).then((all) => all.firstWhere((k) => k.parentId != null && k.id != reviewer.id));
      expect((fixer.mode, fixer.nativeMode), (AgentMode.fullAuto, 'auto'));
    });
  });

  test("an agent can list the workflow prompts before its session's start returns", () async {
    final gate = drivers['test']!.startGate = Completer<void>();
    final starting = container
        .read(codeSessionsProvider.notifier)
        .start(
          project: container.read(codeProjectsProvider).single,
          prompt: 'Lead the work',
          model: '',
          mode: AgentMode.autoEdit,
          harness: 'test',
        );
    final host = container.read(hostServerProvider) as FakeHost;
    for (var i = 0; i < 50 && host.tools.isEmpty; i++) {
      await pumpEventQueue();
    }
    // Gemini over ACP lists prompts inside session/new, which is what the start waits for.
    final prompts = await (host.tools.values.single as HostPrompts).workflowPrompts();
    expect([for (final p in prompts) p.id], ['ultra', 'bugfix', 'security_review']);
    gate.complete();
    await starting;
  });

  test('a schema reply that misses gets its repair message in the same child', () async {
    final c = await open();
    await c.runWorkflow('demo', 'source');
    final reply = bridge.agent('Review', {
      'harness': 'fake2',
      'schema': {
        'type': 'object',
        'required': ['ok'],
      },
    });
    await child();
    final s = drivers['fake2']!.latest!;
    answer(s, 'Looks fine');
    // The repair goes through the child's own send, which reads its folder first.
    for (var i = 0; i < 50 && s.sent.length < 2; i++) {
      await pumpEventQueue();
    }
    expect(s.sent.last, contains("doesn't match the schema"));
    answer(s, '```json\n{"ok": true}\n```');
    expect(await reply, {'ok': true});
    expect(drivers['fake2']!.specs, hasLength(1));
  });

  test('a harness that needs consent refuses the agent', () async {
    final c = await open();
    await c.runWorkflow('demo', 'source');
    await expectLater(bridge.agent('Fix', {'harness': 'cli'}), throwsA(contains('Use my own installed CLIs')));
    expect(drivers['cli']!.specs, isEmpty);
  });

  group('landing', () {
    const run = WorkflowRun(runId: 'abcdef123', name: 'Bug fix', state: RunEnded(WorkflowOutcome.done));

    /// A session in a git repository with a file the workflow left uncommitted.
    Future<(CodeSessionController, String)> dirty() async {
      await git(['init', '-q']);
      await git(['config', 'user.name', 't']);
      await git(['config', 'user.email', 't@t']);
      File('${project.path}/a.txt').writeAsStringSync('one\n');
      await git(['add', '.']);
      await git(['commit', '-qm', 'init']);
      final c = await open();
      final dir = container.read(codeSessionsProvider.notifier).byId(c.sessionId)!.diffTarget!.path;
      File('$dir/b.txt').writeAsStringSync('two\n');
      container.read(workflowOwnPathsProvider(c.sessionId).notifier).set(run.runId, ['b.txt']);
      return (c, dir);
    }

    Future<String> told() async {
      for (var i = 0; i < 50 && !lead.sent.any((m) => m.contains('<workflow-landing')); i++) {
        await pumpEventQueue();
      }
      return lead.sent.singleWhere((m) => m.contains('<workflow-landing'));
    }

    WorkflowLanded? landed(CodeSessionController c) => container.read(workflowLandingProvider(c.sessionId))[run.runId];

    Future<String> out(String dir, List<String> args) async =>
        '${(await Process.run('git', ['-C', dir, ...args])).stdout}'.trim();

    test('the card asks only when the folder is dirty', () async {
      final (c, dir) = await dirty();
      final key = (sessionId: c.sessionId, runId: run.runId);
      expect(await container.read(workflowDirtyProvider(key).future), isTrue);
      await c.landWorkflow(run, WorkflowLand.commit, message: 'Bug fix: two');
      container.invalidate(workflowDirtyProvider(key));
      expect(await container.read(workflowDirtyProvider(key).future), isFalse);
      expect(await out(dir, ['log', '-1', '--format=%s']), 'Bug fix: two');
    });

    test('Commit here commits the folder and tells the lead once', () async {
      final (c, dir) = await dirty();
      await c.landWorkflow(run, WorkflowLand.commit, message: 'Bug fix: two');
      expect(landed(c)!.ok, isTrue);
      expect(landed(c)!.text, startsWith('Committed '));
      final msg = await told();
      expect(msg, contains('<workflow-landing run="abcdef123" choice="commit" commit="'));
      expect(msg, isNot(contains('branch=')));
      expect(await out(dir, ['status', '--porcelain']), isEmpty);
    });

    test('New branch commits on a branch of that name; a bad name changes nothing and tells no one', () async {
      final (c, dir) = await dirty();
      final before = await out(dir, ['rev-parse', 'HEAD']);
      await c.landWorkflow(run, WorkflowLand.branch, message: 'x', branch: 'not a branch');
      expect(landed(c)!.ok, isFalse);
      expect(await out(dir, ['rev-parse', 'HEAD']), before);
      expect(await out(dir, ['status', '--porcelain']), isNotEmpty);
      expect(lead.sent.where((m) => m.contains('<workflow-landing')), isEmpty);

      await c.landWorkflow(run, WorkflowLand.branch, message: 'Bug fix: two', branch: 'everyai/bug-fix-abcdef');
      expect(landed(c)!.ok, isTrue);
      expect(landed(c)!.text, contains('on everyai/bug-fix-abcdef'));
      expect(await out(dir, ['branch', '--show-current']), 'everyai/bug-fix-abcdef');
      expect(await told(), contains('choice="branch" branch="everyai/bug-fix-abcdef"'));
    });

    test('only the run\'s own files are committed, not the user\'s work in the same folder', () async {
      final (c, dir) = await dirty();
      File('$dir/notes.txt').writeAsStringSync('mine\n');
      File('$dir/a.txt').writeAsStringSync('one, edited by me\n');
      await c.landWorkflow(run, WorkflowLand.commit, message: 'Bug fix: two');
      expect(await out(dir, ['show', '--name-only', '--format=', 'HEAD']), 'b.txt');
      expect(await out(dir, ['status', '--porcelain']), allOf(contains('notes.txt'), contains('a.txt')));
      // The other cards re-check: nothing of this run is left.
      final key = (sessionId: c.sessionId, runId: run.runId);
      expect(await container.read(workflowDirtyProvider(key).future), isFalse);
    });

    test('a run that changed nothing has nothing to commit or switch to', () async {
      final (c, dir) = await dirty();
      container.read(workflowOwnPathsProvider(c.sessionId).notifier).set(run.runId, const []);
      final key = (sessionId: c.sessionId, runId: run.runId);
      expect(await container.read(workflowDirtyProvider(key).future), isFalse);
      final before = await out(dir, ['rev-parse', 'HEAD']);
      await c.landWorkflow(run, WorkflowLand.branch, message: 'x', branch: 'everyai/none');
      expect(landed(c)!.text, 'Nothing was left to commit.');
      expect(await out(dir, ['rev-parse', 'HEAD']), before);
      expect(await out(dir, ['branch', '--show-current']), isNot('everyai/none'));
      expect(await told(), isNot(contains('branch=')));
    });

    test('a run records the files it changed, and only those get the lead\'s wait-for-the-user note', () async {
      await git(['init', '-q']);
      await git(['config', 'user.name', 't']);
      await git(['config', 'user.email', 't@t']);
      File('${project.path}/a.txt').writeAsStringSync('one\n');
      await git(['add', '.']);
      await git(['commit', '-qm', 'init']);
      // Already there when the run starts: not the run's.
      File('${project.path}/wip.txt').writeAsStringSync('mine\n');
      final c = await open();
      await c.runWorkflow('demo', 'source');
      File('${project.path}/made.txt').writeAsStringSync('by the run\n');
      // The git calls at the end are real processes, so wait for the files to be recorded, not for turns.
      final recorded = Completer<void>();
      container.listen(workflowOwnPathsProvider(c.sessionId), (_, now) {
        if (now.isNotEmpty && !recorded.isCompleted) recorded.complete();
      });
      bridge.finish({'fixed': true});
      await recorded.future;
      for (var i = 0; i < 5000 && !lead.sent.any((m) => m.contains('<workflow-result')); i++) {
        await pumpEventQueue();
      }
      final paths = container.read(workflowOwnPathsProvider(c.sessionId)).values.single;
      expect(paths, ['made.txt']);
      expect(lead.sent.singleWhere((m) => m.contains('<workflow-result')), contains('you will be told'));
    });

    test('a lane that merged brings its own commits over before the last one', () async {
      final (c, dir) = await dirty();
      final fork = (await GitService.forkCopy(dir, worktreesDir: '${project.parent.path}/forks', slug: 'lane1'))!;
      File('${fork.root}/c.txt').writeAsStringSync('lane\n');
      await Process.run('git', ['-C', fork.root, 'add', '-A']);
      await Process.run('git', [
        '-C', fork.root, '-c', 'user.name=Worker', '-c', 'user.email=w@w', //
        'commit', '-qm', 'Add c\n\nCo-Authored-By: Claude <noreply@anthropic.com>',
      ]);
      final m = await GitService.mergeFork(fork, slug: 'lane1');
      container.read(workflowOwnPathsProvider(c.sessionId).notifier).set(run.runId, ['b.txt', 'c.txt']);
      container.read(workflowLanesProvider(c.sessionId).notifier).add(run.runId, (
        ref: m.ref,
        base: fork.base,
        label: 'Lane 1',
      ));
      await c.landWorkflow(run, WorkflowLand.commit, message: 'Bug fix: two');
      expect(landed(c)!.text, contains("after the workers' 1 commit"));
      expect(await out(dir, ['log', '--format=%s|%an', '-2']), 'Bug fix: two|t\nAdd c|Worker');
      expect(await out(dir, ['log', '--format=%B', '-2']), isNot(contains('Claude')));
      expect(await out(dir, ['status', '--porcelain']), isEmpty);
      expect(await told(), contains("The workers' own 1 commit came over first"));
    });

    test('Leave uncommitted touches nothing and still tells the lead', () async {
      final (c, dir) = await dirty();
      await c.landWorkflow(run, WorkflowLand.leave);
      expect(landed(c)!.text, 'Left uncommitted.');
      expect(await out(dir, ['status', '--porcelain']), isNotEmpty);
      expect(await told(), contains('choice="leave"'));
    });
  });

  test('a finished run tells the lead its changes are not committed yet', () async {
    final c = await open();
    await c.runWorkflow('demo', 'source');
    bridge.finish({'fixed': true});
    for (var i = 0; i < 50 && !lead.sent.any((m) => m.contains('<workflow-result')); i++) {
      await pumpEventQueue();
    }
    final msg = lead.sent.singleWhere((m) => m.contains('<workflow-result'));
    expect(msg, contains('not committed'));
    // Nothing for the user to choose here, so the lead is not left waiting for a note.
    expect(msg, isNot(contains('you will be told')));
    expect(msg, contains('Do not commit them unless the user asks'));
  });

  test('a worktree agent works in its own copy, merged back when it finishes', () async {
    await git(['init', '-q']);
    File('${project.path}/a.txt').writeAsStringSync('one\n');
    await git(['add', '.']);
    await git(['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'init']);
    final c = await open();
    await c.runWorkflow('demo', 'source');
    final reply = bridge.agent('Add b', {'harness': 'fake2', 'worktree': true});
    final info = await child();
    expect(info.workingDir, isNot(project.path));
    expect(info.forkCopy, isNotNull);
    File('${info.workingDir}/b.txt').writeAsStringSync('two\n');
    answer(drivers['fake2']!.latest!, 'Added b');
    final text = await reply as String;
    expect(text, startsWith('Added b'));
    expect(text, contains('b.txt'));
    expect(File('${project.path}/b.txt').readAsStringSync(), 'two\n');
  });

  Future<void> repo() async {
    await git(['init', '-q']);
    File('${project.path}/a.txt').writeAsStringSync('one\n');
    await git(['add', '.']);
    await git(['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'init']);
  }

  test('while the lead plans, the work of a worktree agent is kept on its ref, not merged', () async {
    await repo();
    final c = await open();
    await c.setMode(AgentMode.plan);
    await c.runWorkflow('demo', 'source');
    final reply = bridge.agent('Add b', {'harness': 'fake2', 'worktree': true});
    final info = await child();
    File('${info.workingDir}/b.txt').writeAsStringSync('two\n');
    answer(drivers['fake2']!.latest!, 'Added b');
    final text = await reply as String;
    expect(text, contains('Not merged while planning'));
    expect(File('${project.path}/b.txt').existsSync(), isFalse);
  });

  test('stopping the run ends the watch on a working agent, so its worktree is settled', () async {
    await repo();
    final c = await open();
    final runId = await c.runWorkflow('demo', 'source');
    final reply = bridge.agent('Add b', {'harness': 'fake2', 'worktree': true});
    final info = await child();
    drivers['fake2']!.latest!.add(stateEvent('s-r', ExecutionStatus.running));
    await pumpEventQueue();
    c.stopWorkflow(runId);
    await expectLater(reply, throwsA(anything));
    await whenValue(
      container,
      codeSessionsProvider,
      (List<CodeSessionInfo> all) => all.firstWhere((s) => s.id == info.id).forkCopy == null,
    );
  });

  test('Stop all ends the workflow run and its agent, and nothing wakes the lead afterwards', () async {
    final c = await open();
    await c.runWorkflow('demo', 'source');
    final reply = bridge.agent('Look around', {'harness': 'fake2'});
    await child();
    drivers['fake2']!.latest!.add(stateEvent('s-r', ExecutionStatus.running));
    await pumpEventQueue();
    expect(c.runningWork.workflows, ['demo']);
    final before = lead.sent.length;
    final agentStopped = expectLater(reply, throwsA(anything));
    await c.stopAll();
    await agentStopped;
    await whenValue(
      container,
      workflowRunsProvider(c.sessionId),
      (List<WorkflowRun> r) => r.single.status != WorkflowStatus.running,
    );
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }
    expect(c.runningWork.workflows, isEmpty);
    expect(lead.sent.skip(before).where((m) => m.contains('<workflow-result')), isEmpty);
  });

  test("the user's Stop shuts the run down: its agent is released, the lead hears, and a new run may start", () async {
    final c = await open();
    final runId = await c.runWorkflow('demo', 'source');
    final reply = bridge.agent('Look around', {'harness': 'fake2'});
    final info = await child();
    drivers['fake2']!.latest!.add(stateEvent('s-r', ExecutionStatus.running));
    await pumpEventQueue();
    final before = lead.sent.length;
    final agentStopped = expectLater(reply, throwsA(anything));
    c.stopWorkflow(runId);
    await agentStopped;
    final runs = await whenValue(
      container,
      workflowRunsProvider(c.sessionId),
      (List<WorkflowRun> r) => r.single.state is RunEnded,
    );
    expect(runs.single.status, WorkflowStatus.stopped);
    // The child was stopped through its controller (its own processes with it), and stays open to read.
    expect(drivers['fake2']!.latest!.interrupts, greaterThan(0));
    expect(container.read(codeSessionsProvider).firstWhere((s) => s.id == info.id).ownTag, isTrue);
    for (var i = 0; i < 100 && !lead.sent.skip(before).any((m) => m.contains('<workflow-result')); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final told = lead.sent.skip(before).firstWhere((m) => m.contains('<workflow-result'));
    expect(told, contains('status="stopped"'));
    expect(told, contains('Stopped by the user.'));
    // The journal is retired, and the slot is free: the next run starts.
    expect(File('${tmp.path}/data/workflows/${c.sessionId}/$runId.jsonl').existsSync(), isFalse);
    bridge = FakeBridge();
    final next = await c.runWorkflow('demo', 'source');
    expect(next, isNot(runId));
    expect(info.id, isNotEmpty);
  });

  test('at app start a run left stopping is finished without its session being opened', () async {
    final c = await open();
    final id = c.sessionId;
    // A run the app quit while it was stopping: started, an agent spawned, the stop journalled, no end.
    final dir = Directory('${tmp.path}/data/workflows/$id')..createSync(recursive: true);
    final path = '${dir.path}/r-left.jsonl';
    File(path).writeAsStringSync(
      [
        jsonEncode({'t': 'start', 'name': 'demo', 'source': 'src', 'args': const <String, Object?>{}, 'at': 0}),
        jsonEncode({'t': 'stop', 'outcome': 'stopped', 'why': 'Stopped by the user.'}),
      ].join('\n'),
    );
    // The app's next start: no controller yet (nobody opened the session).
    container.invalidate(codeSessionProvider(id));
    final before = lead.sent.length;
    final opened = await container.read(workflowResumeProvider.future);
    expect(opened, [id]);
    final runs = await whenValue(
      container,
      workflowRunsProvider(id),
      (List<WorkflowRun> r) => r.any((x) => x.runId == 'r-left' && x.state is RunEnded),
    );
    expect(runs.firstWhere((x) => x.runId == 'r-left').status, WorkflowStatus.stopped);
    expect(File(path).existsSync(), isFalse);
    // No script ran for it.
    expect(bridge.killed, isFalse);
    for (var i = 0; i < 100 && !lead.sent.skip(before).any((m) => m.contains('<workflow-result')); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(lead.sent.skip(before).where((m) => m.contains('status="stopped"')), hasLength(1));
  });

  test('a run Stop all ended, resumed at app start, still wakes no lead', () async {
    final c = await open();
    final id = c.sessionId;
    final dir = Directory('${tmp.path}/data/workflows/$id')..createSync(recursive: true);
    final path = '${dir.path}/r-quiet.jsonl';
    File(path).writeAsStringSync(
      [
        jsonEncode({'t': 'start', 'name': 'demo', 'source': 'src', 'args': const <String, Object?>{}, 'at': 0}),
        jsonEncode({'t': 'stop', 'outcome': 'stopped', 'why': 'Stopped.', 'quiet': true}),
      ].join('\n'),
    );
    container.invalidate(codeSessionProvider(id));
    final before = lead.sent.length;
    await container.read(workflowResumeProvider.future);
    await whenValue(
      container,
      workflowRunsProvider(id),
      (List<WorkflowRun> r) => r.any((x) => x.runId == 'r-quiet' && x.state is RunEnded),
    );
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }
    expect(lead.sent.skip(before).where((m) => m.contains('<workflow-result')), isEmpty);
    expect(File(path).existsSync(), isFalse);
  });

  test('a resumed run whose lead step outlasts its cutoff tells the lead once and retires its journal', () async {
    final c = await open();
    final id = c.sessionId;
    final dir = Directory('${tmp.path}/data/workflows/$id')..createSync(recursive: true);
    final path = '${dir.path}/r-slow.jsonl';
    File(path).writeAsStringSync(
      [
        jsonEncode({'t': 'start', 'name': 'demo', 'source': 'src', 'args': const <String, Object?>{}, 'at': 0}),
        jsonEncode({'t': 'stop', 'outcome': 'stopped', 'why': 'Stopped by the user.'}),
      ].join('\n'),
    );
    // The lead's history arrives after the lead step's cutoff: the workflow step runs first.
    CodeSessionController.workflowStepTimeout = const Duration(milliseconds: 50);
    CodeSessionController.liveAfter = const Duration(milliseconds: 400);
    addTearDown(() {
      CodeSessionController.workflowStepTimeout = const Duration(seconds: 30);
      CodeSessionController.liveAfter = const Duration(milliseconds: 1500);
    });
    container.invalidate(codeSessionProvider(id));
    final before = lead.sent.length;
    await container.read(workflowResumeProvider.future);
    for (var i = 0; i < 200 && !lead.sent.skip(before).any((m) => m.contains('<workflow-result')); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(lead.sent.skip(before).where((m) => m.contains('status="stopped"')), hasLength(1));
    for (var i = 0; i < 50 && File(path).existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Left on disk, the next launch would resume into this shutdown and tell the lead a second time.
    expect(File(path).existsSync(), isFalse);
  });

  test('end_workflow waits for a workflow run the Max lead started', () async {
    final c = await open();
    final sessions = container.read(codeSessionsProvider.notifier);
    sessions.update(sessions.byId(c.sessionId)!.copyWith(workflow: maxWorkflowId));
    HostCall end() => HostCall(
      id: 'h2',
      sessionId: '',
      name: endWorkflowTool,
      args: const {'outcome': 'done'},
      ended: Completer<HostEnd>().future,
    );
    await c.runWorkflow('demo', 'source');
    final early = await c.call(end());
    expect(early.isError, isTrue);
    expect(early.text, contains('workflow run'));
    expect(sessions.byId(c.sessionId)!.workflow, maxWorkflowId);
    bridge.finish({'ok': true});
    await whenValue(
      container,
      workflowRunsProvider(c.sessionId),
      (List<WorkflowRun> r) => r.isNotEmpty && r.single.state is RunEnded,
    );
    // The shutdown's last step (the journal retired, then the slot freed) follows the card's end.
    var ended = await c.call(end());
    for (var i = 0; i < 500 && ended.isError; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ended = await c.call(end());
    }
    expect(ended.text, startsWith('Max is off'));
    expect(sessions.byId(c.sessionId)!.workflow, isNull);
  });

  test('a run the app quit in the middle of carries on when the session opens again', () async {
    final c = await open();
    final id = c.sessionId;
    final runId = await c.runWorkflow('demo', 'the source', args: {'n': 2});
    // Killed with the script: nobody hears this one.
    unawaited(bridge.agent('Fix', {'harness': 'fake2'}).catchError((Object _) => null));
    final first = await child();
    // Still at work: the session closed, not the app.
    drivers['fake2']!.latest!.add(stateEvent('w-r', ExecutionStatus.running));
    // The app quits: the script dies, the journal has the spawn but no answer.
    final old = bridge;
    bridge = FakeBridge();
    container.invalidate(codeSessionProvider(id));
    await pumpEventQueue();
    expect(old.killed, isTrue);
    final journal = File('${tmp.path}/data/workflows/$id/$runId.jsonl').readAsLinesSync();
    expect(journal.map((l) => (jsonDecode(l) as Map)['t']), ['start', 'spawn']);
    final runs = await whenValue(
      container,
      workflowRunsProvider(id),
      (List<WorkflowRun> r) => r.isNotEmpty && r.last.status == WorkflowStatus.running && r.last.agents.isEmpty,
    );
    expect(runs.last.runId, runId);
    // The script runs again: the same call reattaches to the child it started.
    final again = bridge.agent('Fix', {'harness': 'fake2'});
    await pumpEventQueue();
    answer(drivers['fake2']!.latest!, 'Fixed');
    expect(await again, 'Fixed');
    expect(drivers['fake2']!.specs, hasLength(1));
    expect(container.read(codeSessionsProvider).where((s) => s.parentId == id).single.id, first.id);
    expect(drivers['fake2']!.latest!.sent.where((m) => m.contains(workflowCarryOn)), isEmpty);
  });

  test('an agent whose turn died with the app is told to carry on when the run resumes', () async {
    CodeSessionController.liveAfter = Duration.zero;
    addTearDown(() => CodeSessionController.liveAfter = const Duration(milliseconds: 1500));
    final c = await open();
    final id = c.sessionId;
    await c.runWorkflow('demo', 'the source');
    unawaited(bridge.agent('Fix', {'harness': 'fake2'}).catchError((Object _) => null));
    final first = await child();
    expect(first.harness, 'fake2');
    // Mid-turn when the app quits: its history ends "working".
    drivers['fake2']!.latest!.add(stateEvent('w-r', ExecutionStatus.running));
    await pumpEventQueue();
    container.dispose();
    bridge = FakeBridge();
    container = makeContainer();
    container.listen(codeSessionProvider(id), (_, _) {});
    await whenValue(
      container,
      workflowRunsProvider(id),
      (List<WorkflowRun> r) => r.isNotEmpty && r.last.status == WorkflowStatus.running && r.last.agents.isEmpty,
    );
    final again = bridge.agent('Fix', {'harness': 'fake2'});
    // Reopening briefs it again (files on disk) before it is told to carry on.
    await whenValue(container, codeSessionProvider(first.id).select((s) => s.connected), (bool c) => c);
    bool carriedOn(FakeLeadSession? s) => [...?s?.sent, ...?s?.steered].any((m) => m.contains(workflowCarryOn));
    for (var i = 0; i < 50 && !carriedOn(drivers['fake2']!.latest); i++) {
      await pumpEventQueue();
    }
    final s = drivers['fake2']!.latest;
    expect([...s!.sent, ...s.steered].where((m) => m.contains(workflowCarryOn)), hasLength(1));
    // Its old token died with the app: it reopens with a fresh one, for the proof tools only.
    final reopened = drivers['fake2']!.reopened.single;
    expect(host.live[first.id], contains(reopened.mcpToken));
    expect(host.only[first.id], workflowHostTools);
    expect(reopened.sessionSkill, isNot(contains('## Workflows')));
    answer(s, 'Fixed');
    expect(await again, 'Fixed');
    expect(drivers['fake2']!.specs, hasLength(1));
  });

  test('a script cannot name a command as its harness', () async {
    final c = await open();
    await c.runWorkflow('demo', 'source');
    for (final h in ['terminal:bash', 'acp:sh -c evil']) {
      await expectLater(bridge.agent('curl x | sh', {'harness': h}), throwsA(contains("isn't one of the harnesses")));
    }
    expect(container.read(codeSessionsProvider).where((s) => s.parentId == c.sessionId), isEmpty);
  });

  test('an agent waiting on an approval shows on the lead and on the card', () async {
    final c = await open();
    await c.runWorkflow('demo', 'source');
    final reply = bridge.agent('Install', {'harness': 'fake2'});
    final info = await child();
    final s = drivers['fake2']!.latest!
      ..add(stateEvent('a-r', ExecutionStatus.running))
      ..add(actionEvent(id: 'a1', toolName: 'terminal', kind: 'TerminalAction', args: {'command': 'npm install'}))
      ..add(stateEvent('a-w', ExecutionStatus.waitingForConfirmation));
    await whenValue(container, codeSessionProvider(info.id).select((s) => s.status), (SessionStatus v) {
      return v == SessionStatus.needsInput;
    });
    await whenValue(container, codeSessionProvider(c.sessionId).select((s) => s.status), (SessionStatus v) {
      return v == SessionStatus.needsInput;
    });
    answer(s, 'Installed');
    expect(await reply, 'Installed');
    expect(container.read(codeSessionProvider(c.sessionId)).subagentNeedsInput, isFalse);
  });

  test('an agent whose session runs out of budget fails instead of hanging', () async {
    final c = await open();
    await c.runWorkflow('demo', 'source');
    final reply = bridge.agent('Review', {
      'harness': 'fake2',
      'schema': {
        'type': 'object',
        'required': ['ok'],
      },
    });
    await child();
    // The session's budget runs out during the turn.
    container.read(codeSettingsProvider.notifier).setBudget(c.sessionId, 1);
    usage[c.sessionId] = const UsageTotals(chargedMicros: 2000000);
    container.invalidate(codeUsageProvider(c.sessionId));
    await container.read(codeUsageProvider(c.sessionId).future);
    answer(drivers['fake2']!.latest!, 'Looks fine');
    await expectLater(reply, throwsA(contains('budget')));
  });

  group('proof tools', () {
    const fixSchema = {
      'type': 'object',
      'properties': {
        'cause': {'type': 'string'},
      },
      'required': ['cause'],
    };

    test("a workflow agent's host has only the proof tools, and its briefing no workflows", () async {
      final c = await open();
      await c.runWorkflow('demo', 'source');
      unawaited(bridge.agent('Fix', {'harness': 'fake2'}).catchError((Object _) => null));
      final info = await child();
      expect(info.isWorkflowAgent, isTrue);
      expect(host.only[info.id], workflowHostTools);
      // The memory is in its instructions; the lead decides what is kept.
      expect(workflowHostTools, isNot(contains('memory')));
      expect(host.only[c.sessionId], isNull);
      final text = drivers['fake2']!.specs.single.briefing!.sessionSkill!;
      final tools = text.substring(text.indexOf('## everyai tools'), text.indexOf('## Rules'));
      expect(
        RegExp(r'^- `(\w+)`', multiLine: true).allMatches(tools).map((m) => m[1]),
        unorderedEquals(workflowHostTools),
      );
      expect(text, isNot(contains('## Workflows')));
      expect(text, isNot(contains('run_workflow')));
      expect(await (host.tools[info.id]! as HostPrompts).workflowPrompts(), isEmpty);
    });

    test("a workflow agent's read-only proof tools run, its commands ask", () async {
      final c = await open();
      await c.runWorkflow('demo', 'source');
      unawaited(bridge.agent('Fix', {'harness': 'fake2'}).catchError((Object _) => null));
      final info = await child();
      final policy = container.read(codeSessionProvider(info.id).notifier).policy;
      ActionCall mcp(String name) => ActionCall(
        id: name,
        raw: const {},
        toolName: 'mcp__everyai__$name',
        toolCallId: name,
        action: const {'kind': 'MCPToolAction'},
      );
      expect(policy.decide(mcp('diff_stats'), AgentMode.autoEdit).verdict, Verdict.allow);
      expect(policy.decide(mcp('bug_check'), AgentMode.autoEdit).verdict, Verdict.ask);
    });

    test("bug_check's record comes from the child's state file, seeded before its first turn", () async {
      final c = await open();
      await c.runWorkflow('demo', 'source');
      File('${project.path}/test/repro_test.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('// repro');
      final seed = {
        'available': true,
        'state': 'verified',
        'command': 'dart test test/repro_test.dart',
        'expect': 'Expected: 3',
        // A git-excluded script stayed in the fixer's checkout: its absence here isn't a change to the repro.
        'files': {'test/repro_test.dart': 'abc', '.everyai/scratch/repro.sh': 'def'},
      };
      final reply = bridge.agent('Refix', {'harness': 'fake2', 'schema': fixSchema, 'bugCheck': seed});
      final info = await child();
      final state = File('${tmp.path}/data/driver-sessions/${info.id}/bug_check.json');
      expect(jsonDecode(state.readAsStringSync()), {
        'command': 'dart test test/repro_test.dart',
        'expect': 'Expected: 3',
        'files': {'test/repro_test.dart': 'abc'},
        'verified': false,
      });
      // The child verifies (the host writes the state), and says something else itself.
      state.writeAsStringSync(
        jsonEncode({
          'command': 'dart test test/repro_test.dart',
          'expect': '',
          'files': <String, Object?>{},
          'verified': true,
        }),
      );
      answer(drivers['fake2']!.latest!, '```json\n{"cause": "off by one", "bug_check": {"state": "made up"}}\n```');
      final value = await reply as Map;
      expect(value['bug_check'], {
        'available': true,
        'state': 'verified',
        'command': 'dart test test/repro_test.dart',
        'expect': '',
        'files': <String, Object?>{},
      });
    });

    test('a fresh bug_check is not_reproduced; an agent with no host says why', () async {
      final c = await open();
      await c.runWorkflow('demo', 'source');
      var reply = bridge.agent('Fix', {'harness': 'fake2', 'schema': fixSchema, 'bugCheck': true});
      final first = await child();
      answer(drivers['fake2']!.latest!, '```json\n{"cause": "x"}\n```');
      expect(((await reply as Map)['bug_check'] as Map)['state'], 'not_reproduced');
      host.mintFails = StateError('no port');
      reply = bridge.agent('Fix again', {'harness': 'fake2', 'schema': fixSchema, 'bugCheck': true});
      final second = await whenValue(
        container,
        codeSessionsProvider,
        (List<CodeSessionInfo> all) => all.any((s) => s.isWorkflowAgent && s.id != first.id),
      ).then((all) => all.firstWhere((s) => s.isWorkflowAgent && s.id != first.id));
      expect(drivers['fake2']!.specs.last.briefing, isNull);
      expect(second.title, isNotEmpty);
      answer(drivers['fake2']!.latest!, '```json\n{"cause": "x"}\n```');
      final record = (await reply as Map)['bug_check'] as Map;
      expect(record['available'], isFalse);
      expect(record['why'], contains('no port'));
    });

    test('an agent reopened after a restart without a host says so in its record', () async {
      CodeSessionController.liveAfter = Duration.zero;
      addTearDown(() => CodeSessionController.liveAfter = const Duration(milliseconds: 1500));
      final c = await open();
      final id = c.sessionId;
      await c.runWorkflow('demo', 'source');
      final call = {'harness': 'fake2', 'schema': fixSchema, 'bugCheck': true};
      unawaited(bridge.agent('Fix', call).catchError((Object _) => null));
      final first = await child();
      // It reproduced the bug, then the app quit mid-turn.
      File('${tmp.path}/data/driver-sessions/${first.id}/bug_check.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'command': 'make repro', 'expect': '', 'files': <String, Object?>{}}));
      drivers['fake2']!.latest!.add(stateEvent('w-r', ExecutionStatus.running));
      await pumpEventQueue();
      container.dispose();
      bridge = FakeBridge();
      host.mintFails = StateError('no port');
      container = makeContainer();
      container.listen(codeSessionProvider(id), (_, _) {});
      await whenValue(
        container,
        workflowRunsProvider(id),
        (List<WorkflowRun> r) => r.isNotEmpty && r.last.status == WorkflowStatus.running && r.last.agents.isEmpty,
      );
      final again = bridge.agent('Fix', call);
      await whenValue(container, codeSessionProvider(first.id).select((s) => s.connected), (bool c) => c);
      expect(drivers['fake2']!.reopened, isEmpty);
      answer(drivers['fake2']!.latest!, '```json\n{"cause": "x"}\n```');
      final record = (await again as Map)['bug_check'] as Map;
      expect(record['available'], isFalse);
      expect(record['why'], allOf(contains('restarted'), contains('no port')));
    });
  });

  group('the estimate', () {
    HostCall ultra(List<String> items, {String id = 'h-u'}) => HostCall(
      id: id,
      sessionId: '',
      name: runWorkflowTool,
      args: {
        'id': 'ultra',
        'args': {
          'items': [
            for (final i in items) {'id': i, 'title': 'Item $i', 'spec': 'Build $i'},
          ],
        },
      },
      ended: Completer<HostEnd>().future,
    );

    WorkflowProposal? card(CodeSessionController c) => container.read(codeSessionProvider(c.sessionId)).proposal;

    test('agents per item, the items listed; a second call replaces the open card', () async {
      final c = await open();
      await c.call(ultra(['a', 'b']));
      expect(card(c)!.items, ['Item a', 'Item b']);
      expect(card(c)!.estimate.agents, (9, 12));
      expect(card(c)!.phases.first, 'Split');
      final first = card(c)!.id;
      final again = await c.call(ultra(['a', 'b', 'c'], id: 'h-2'));
      expect(again.isError, isFalse);
      expect(card(c)!.id, isNot(first));
      expect(card(c)!.estimate.agents, (13, 17));
      expect(startedArgs, isNull);
    });

    test('Cancel runs nothing and tells the lead; the slot is free again', () async {
      final c = await open();
      await c.call(ultra(['a']));
      c.cancelProposal();
      await pumpEventQueue();
      expect(card(c), isNull);
      expect(startedArgs, isNull);
      expect(lead.sent.last, contains('cancelled the Ultra run before it started'));
      expect((await c.call(ultra(['b']))).isError, isFalse);
    });

    test("Adjust prefills the composer, and the user's next message asks the lead for a new proposal", () async {
      final c = await open();
      await c.call(ultra(['a']));
      c.adjustProposal();
      final s = container.read(codeSessionProvider(c.sessionId));
      expect(s.proposal, isNull);
      expect(s.composerPrefill!.text, 'Change the Ultra run: ');
      await c.send('Change the Ultra run: drop the review');
      await pumpEventQueue();
      expect(lead.sent.last, contains('state="adjust"'));
      expect(lead.sent.last, contains('drop the review'));
      await c.send('and something else');
      await pumpEventQueue();
      expect(lead.sent.last, isNot(contains('state="adjust"')), reason: 'the note goes once');
    });

    test('an open card survives a restart; a started one leaves nothing behind', () async {
      final c = await open();
      await c.call(ultra(['a']));
      final id = card(c)!.id;
      await pumpEventQueue();
      final saved = File('${tmp.path}/data/workflows/${c.sessionId}/proposal.jsonl');
      // Written in the background: a loaded machine may take a moment.
      for (var i = 0; i < 100 && !saved.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(saved.existsSync(), isTrue);
      container.dispose();
      container = makeContainer();
      container.listen(codeSessionProvider(c.sessionId), (_, _) {});
      final back = await whenValue(
        container,
        codeSessionProvider(c.sessionId).select((s) => s.proposal?.id),
        (String? p) => p != null,
      );
      expect(back, id);
      final again = container.read(codeSessionProvider(c.sessionId).notifier);
      await whenValue(container, codeSessionProvider(c.sessionId).select((s) => s.connected), (bool b) => b);
      expect(await again.startProposal(), isNull);
      await pumpEventQueue();
      expect(startedArgs!['items'], isNotEmpty);
      expect(saved.existsSync(), isFalse);
    });

    test('a finished run is remembered for the next estimate in the project', () async {
      final c = await open();
      await c.call(ultra(['a']));
      await start(c);
      final reply = bridge.agent('Build a', {'harness': 'fake2'});
      await child();
      answer(drivers['fake2']!.latest!, 'Built');
      await reply;
      bridge.finish({'ok': true});
      await whenValue(
        container,
        workflowRunsProvider(c.sessionId).select((r) => r.isNotEmpty && r.last.status == WorkflowStatus.done),
        (bool d) => d,
      );
      await pumpEventQueue();
      final past = pastRunsOf(prefs['code.workflow.past.p1']);
      expect(past.single.workflow, 'ultra');
      expect(past.single.everyai, isFalse);
      // An outside lead's runs cost EveryAI nothing: time comes from them, never dollars.
      await c.call(ultra(['a'], id: 'h-3'));
      expect(card(c)!.estimate.dollars, isNull);
      expect(card(c)!.estimate.basis, 'from 1 past run here');
    });

    test("an outside lead's plan windows: the card shows them, and the agents' reports mark the run", () async {
      final c = await open();
      lead.add(
        PlanLimits.of(
          id: 'pl1',
          windows: const [PlanWindow(name: 'five_hour', used: 0.4, minutes: 300)],
        ),
      );
      await pumpEventQueue();
      await c.call(ultra(['a']));
      expect(card(c)!.estimate.planWindows.single.used, 0.4);
      await start(c);
      final reply = bridge.agent('Build a', {'harness': 'fake2'});
      final kid = await child();
      await whenValue(container, codeSessionProvider(kid.id).select((s) => s.connected), (bool b) => b);
      final agent = drivers['fake2']!.latest!;
      // 0.4 + 0.6 × 0.5: half of what was left at the start.
      agent.add(
        PlanLimits.of(
          id: 'pl2',
          windows: const [PlanWindow(name: 'five_hour', used: 0.7, minutes: 300)],
        ),
      );
      await pumpEventQueue();
      final rows = container.read(workflowRunsProvider(c.sessionId)).single.rows;
      expect(rows.single.text, startsWith('5-hour window: 50% of what was left at the start used'));
      answer(agent, 'Built');
      await reply;
      bridge.finish(null);
      await pumpEventQueue();
    });

    test('a picked workflow goes to the lead to clarify and propose; nothing starts by itself', () async {
      final entry = (await loadBundledWorkflows()).firstWhere((w) => w.id == 'bugfix');
      final info = await container
          .read(codeSessionsProvider.notifier)
          .start(
            project: container.read(codeProjectsProvider).single,
            prompt: 'fix it',
            model: '',
            mode: AgentMode.autoEdit,
            harness: 'test',
            workflow: WorkflowPick.script(entry),
          );
      container.listen(codeSessionProvider(info.id), (_, _) {});
      await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
      await pumpEventQueue();
      final first = drivers['test']!.specs.first.initialMessage!;
      expect(first, contains('state="picked"'));
      expect(first, contains('call run_workflow with id "bugfix"'));
      expect(first, contains('{"bug":"fix it"}'));
      expect(startedArgs, isNull);
      expect(container.read(codeSessionProvider(info.id)).proposal, isNull);
    });
  });
}
