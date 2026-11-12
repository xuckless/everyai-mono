import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/process/supervisor.dart' show Ended;
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/harness/session_processes.dart' show killSessionProcesses;
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/subagents.dart' show backgroundStarted, taskTool;
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/acp/acp_mapping.dart' show agentMessageEvent, userMessageEvent;
import 'package:every_ai/features/code/drivers/briefing/briefing_types.dart' show sessionFileName;
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/drivers/usage_limit.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/code/handoff/handoff.dart';
import 'package:every_ai/features/code/handoff/handoff_store.dart';
import 'package:every_ai/features/code/handoff/lead_timeline.dart';
import 'package:every_ai/features/code/handoff/native_import.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart' show NativeMode;
import 'package:every_ai/features/code/host/host_providers.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fake_leads.dart';

const _resume = {DriverCap.approvals, DriverCap.resume};

/// What reached the network: an outside lead's handoff sends nothing (checked after each test, so a call the
/// app caught still fails it).
final _sent = <String>[];
final _noNetwork = MockClient((req) async {
  _sent.add('${req.method} ${req.url}');
  return http.Response('no network in this test', 599);
});

void main() {
  // The app-quit listener needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Directory tmp;
  late Directory project;
  late FakeHost host;
  late Preferences prefs;
  late ProviderContainer container;
  late Map<String, FakeLeadDriver> drivers;
  late NativeImporter? Function(String) importerFor;

  ProviderContainer make() => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(prefs),
      modelCatalogProvider.overrideWith(FixedCatalog.new),
      codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
      driverRegistryProvider.overrideWithValue(DriverRegistry({...drivers})),
      nativeImporterProvider.overrideWithValue((h) => importerFor(h)),
      hostServerProvider.overrideWithValue(host),
      driverDataDirProvider.overrideWithValue(() async => '${tmp.path}/data'),
      gatewayKeysProvider.overrideWith((ref) => throw StateError('no gateway key for outside agents')),
      // A handoff asks no model and fetches nothing: any backend call fails the test.
      apiClientProvider.overrideWithValue(ApiClient(baseUrl: Uri.parse('http://backend/'), client: _noNetwork)),
    ],
  );

  FakeLeadDriver d(String id) => drivers[id]!;
  CodeSessions sessions() => container.read(codeSessionsProvider.notifier);
  CodeSessionInfo infoOf(String id) => sessions().byId(id)!;
  Transcript transcriptOf(String id) => container.read(codeSessionProvider(id)).transcript;

  Future<CodeSessionInfo> start({String harness = 'alpha', AgentMode mode = AgentMode.ask}) => sessions().start(
    project: container.read(codeProjectsProvider).single,
    prompt: 'Add dark mode',
    model: '',
    mode: mode,
    harness: harness,
  );

  Future<CodeSessionController> open(String id) async {
    container.listen(codeSessionProvider(id), (_, _) {});
    await whenValue(container, codeSessionProvider(id).select((s) => s.connected), (bool c) => c);
    return container.read(codeSessionProvider(id).notifier);
  }

  /// [lead]'s conversation plays a turn: the user's message (as sent), a reply, and idle.
  Future<void> turn(FakeLeadSession lead, String id, String reply) async {
    lead
      ..add(userMessageEvent('$id-u', lead.sent.last))
      ..add(agentMessageEvent('$id-a', reply))
      ..add(stateEvent('$id-s', ExecutionStatus.idle));
    await pumpEventQueue();
  }

  /// The session moved to [to] and the switch is over.
  Future<void> handedOff(String id, String to) async {
    await whenValue(
      container,
      codeSessionsProvider.select((all) => all.firstWhere((s) => s.id == id).harness),
      (String h) => h == to,
    );
    await whenValue(container, codeSessionProvider(id).select((s) => s.switching), (bool s) => !s);
  }

  /// Why the automatic handoff didn't happen, once it says.
  Future<String> handoffProblem(String id) =>
      whenValue(container, codeSessionProvider(id).select((s) => s.handoffProblem), (String p) => p.isNotEmpty);

  /// Alpha works on a turn, then stops on its usage limit.
  Future<(CodeSessionInfo, CodeSessionController)> limited() async {
    final info = await start();
    final c = await open(info.id);
    final a = d('alpha').latest!;
    await turn(a, 'a1', 'Added the toggle.');
    a
      ..add(usageLimitEvent('a2-limit', 'You hit your 5-hour limit.', resetsAt: DateTime.utc(2026, 11, 5, 3)))
      ..add(stateEvent('a2-s', ExecutionStatus.error));
    await pumpEventQueue();
    return (info, c);
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('code-lead-switch');
    project = await Directory('${tmp.path}/project').create();
    host = FakeHost();
    drivers = {
      everyaiHarnessName: FakeLeadDriver(everyaiHarnessName, label: 'EveryAI', caps: _resume),
      'alpha': FakeLeadDriver('alpha', label: 'Alpha', caps: _resume),
      'beta': FakeLeadDriver('beta', label: 'Beta', caps: _resume),
      'term': FakeLeadDriver('term', label: 'Term'),
      'off': FakeLeadDriver('off', label: 'Off', status: const DriverStatus(installed: true, signedIn: false)),
      'cli': FakeLeadDriver('cli', label: 'Consent', needsConsent: true),
    };
    importerFor = nativeImporterFor;
    prefs = await Preferences.load(db);
    prefs['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'P', path: project.path).toJson()]);
    container = make();
  });

  tearDown(() async {
    CodeSessionController.liveAfter = const Duration(milliseconds: 1500);
    final sent = [..._sent];
    _sent.clear();
    expect(sent, isEmpty, reason: 'an outside lead reached the network');
    container.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('a usage limit is offered as a switch to the harnesses that are ready', () async {
    final (info, c) = await limited();
    final notice = transcriptOf(info.id).items.last as NoticeItem;
    expect(notice.limit?.resetsAt, DateTime.utc(2026, 11, 5, 3));
    expect(c.limitPick?.limit.message, 'You hit your 5-hour limit.');
    final statuses = await container.read(driverStatusesProvider.future);
    List<String> ready(Set<String> own) => [
      for (final ch in handoffChoices(
        container.read(driverRegistryProvider).listed,
        statuses,
        own,
        current: info.harness,
        ranOut: info.harness,
      ))
        if (ch.blocked == null) ch.info.id,
    ];
    // Not signed in, and not allowed yet, are not ready.
    expect(ready(const {}), [everyaiHarnessName, 'beta', 'term']);
    expect(ready({'cli'}), contains('cli'));
    c.waitForLimit();
    expect(c.limitPick, isNull);
  });

  test('switching hands the new lead everything, and the transcript stays one timeline', () async {
    final (info, c) = await limited();
    final outcome = await c.switchLead('beta', run: true);
    expect(outcome.kind, HandoffKind.full);
    final b = d('beta');
    final first = b.specs.single.initialMessage!;
    // An outside lead gets the handoff without a mode note of ours.
    expect(first, startsWith('$handoffOpen from="alpha" kind="full">'));
    expect(first, contains('Added the toggle.'));
    expect(first, endsWith(carryOnMessage('Alpha')));
    final now = infoOf(info.id);
    expect((now.harness, now.conversationId), ('beta', 'beta-c1'));
    expect(now.leads['alpha']?.conversationId, 'alpha-c1');
    expect(d('alpha').latest!.closed, isTrue);
    // Beta's briefing names no lead (the handoff names Alpha).
    expect(b.specs.single.briefing!.sessionSkill, contains('# EveryAI session'));
    expect(b.specs.single.briefing!.sessionSkill, isNot(contains('Alpha')));
    await turn(b.latest!, 'b1', 'Picked it up.');
    final items = transcriptOf(info.id).items;
    final turns = items.whereType<UserTurn>().toList();
    expect([for (final t in turns) t.lead], ['Alpha', 'Beta']);
    expect(turns.last.text, carryOnMessage('Alpha'));
    final card = items.whereType<NoticeItem>().last;
    expect(card.message, 'Handoff to Beta');
    expect(card.detail, startsWith(handoffOpen));
    expect(items.indexOf(card), lessThan(items.indexOf(turns.last)));
    expect(c.limitPick, isNull);
    // What Alpha did is kept, with the handoff.
    final dir = await sessions().timelineDir(info.id);
    final timeline = await readTimeline(dir);
    expect([for (final s in timeline) (s.harness, s.conversationId)], [('alpha', 'alpha-c1')]);
    expect((await loadHandoffs(dir)).single.kind, HandoffKind.full);
  });

  test('a handoff asks no model and fetches nothing; the whole conversation waits in a file', () async {
    final (info, c) = await limited();
    final outcome = await http.runWithClient(() => c.switchLead('beta', run: true), () => _noNetwork);
    expect(outcome.failed, isFalse);
    final first = d('beta').specs.single.initialMessage!;
    final path = RegExp(r'<transcript>\n(.+)\n</transcript>').firstMatch(first)![1]!;
    expect(path, startsWith('.everyai/handoffs/'));
    final file = File('${project.path}/$path');
    expect(file.readAsStringSync(), contains('# Alpha (conversation alpha-c1)'));
    expect(file.readAsStringSync(), contains('Added the toggle.'));
    expect((await loadHandoffs(await sessions().timelineDir(info.id))).single.transcript, path);
    // The turn had finished before the limit: nothing to finish.
    expect(first, isNot(contains('<cut-turn>')));
    expect(first, endsWith(carryOnMessage('Alpha')));
  });

  test('a turn the limit cut off is finished by the new lead, which redoes nothing', () async {
    final info = await start();
    final c = await open(info.id);
    final a = d('alpha').latest!;
    a
      ..add(userMessageEvent('a1-u', a.sent.last))
      ..add(actionEvent(id: 'a1-c', toolName: 'Bash', kind: 'TerminalAction', args: {'command': 'flutter test'}))
      ..add(resultEvent(id: 'a1-r', actionId: 'a1-c', toolName: 'Bash', text: '2 tests failed'))
      ..add(usageLimitEvent('a1-limit', 'You hit your 5-hour limit.'))
      ..add(stateEvent('a1-s', ExecutionStatus.error));
    await pumpEventQueue();
    expect(c.limitPick, isNotNull);
    await c.switchLead('beta', run: true);
    final first = d('beta').specs.single.initialMessage!;
    expect(first, contains('<cut-turn>'));
    expect(first, contains('Request:\nAdd dark mode'));
    expect(first, contains('flutter test'));
    expect(first, contains('2 tests failed'));
    expect(first, isNot(contains('<last-request>')));
    expect(first, endsWith(carryOnMessage('Alpha', cut: true)));
    final stored = (await loadHandoffs(await sessions().timelineDir(info.id))).single;
    expect(stored.cut?.request, 'Add dark mode');
  });

  test('going back reopens the old conversation with only what it missed', () async {
    final (info, c) = await limited();
    await c.switchLead('beta', run: true);
    await turn(d('beta').latest!, 'b1', 'Wrote the tests.');
    final outcome = await c.switchLead('alpha', run: true);
    expect(outcome.kind, HandoffKind.delta);
    final a = d('alpha');
    expect(a.specs, hasLength(1));
    expect(a.attached, ['alpha-c1']);
    final delta = a.latest!.sent.single;
    expect(delta, contains('kind="delta"'));
    expect(delta, contains('Wrote the tests.'));
    expect(delta, isNot(contains('Added the toggle.')));
    expect(infoOf(info.id).leads.keys, ['beta']);
    await pumpEventQueue();
    // Alpha's conversation replayed its old turn; it shows once.
    final items = transcriptOf(info.id).items;
    expect(items.whereType<AgentText>().where((t) => t.text == 'Added the toggle.'), hasLength(1));
    expect(items.whereType<NoticeItem>().map((n) => n.message), containsAllInOrder(['Handoff to Beta']));
  });

  test("a conversation that can't be reopened gets a new one with everything", () async {
    final (info, c) = await limited();
    await c.switchLead('beta', run: true);
    await turn(d('beta').latest!, 'b1', 'Wrote the tests.');
    d('alpha').attachFails = true;
    final outcome = await c.switchLead('alpha', run: true);
    expect(outcome.kind, HandoffKind.full);
    expect(d('alpha').specs, hasLength(2));
    expect(infoOf(info.id).conversationId, 'alpha-c2');
    expect(d('alpha').specs.last.initialMessage, contains('Added the toggle.'));
  });

  test('alpha, beta, alpha, beta: each return gets only what that lead missed', () async {
    final (info, c) = await limited();
    await c.switchLead('beta', run: true);
    await turn(d('beta').latest!, 'b1', 'Wrote the tests.');
    await c.switchLead('alpha', run: true);
    await turn(d('alpha').latest!, 'a3', 'Fixed the tests.');
    final outcome = await c.switchLead('beta', run: true);
    expect(outcome.kind, HandoffKind.delta);
    expect(d('beta').specs, hasLength(1));
    expect(d('beta').attached, ['beta-c1']);
    final delta = d('beta').latest!.sent.last;
    expect(delta, contains('Fixed the tests.'));
    expect(delta, isNot(contains('Wrote the tests.')));
    expect(delta, isNot(contains('Added the toggle.')));
    expect(infoOf(info.id).leads.keys, ['alpha']);
    expect(infoOf(info.id).conversationId, 'beta-c1');
    await pumpEventQueue();
    final texts = transcriptOf(info.id).items.whereType<AgentText>().map((t) => t.text).toList();
    expect(texts, ['Added the toggle.', 'Wrote the tests.', 'Fixed the tests.']);
  });

  test("a conversation that can't be reopened is copied into its format when it can be", () async {
    importerFor = (h) => h == 'alpha'
        ? _FakeImporter('alpha', (_) {
            // Only the old conversation is gone.
            d('alpha').attachFails = false;
            d('alpha').conversations['alpha-imp'] = FakeLeadSession(id: 'alpha-imp', replays: true);
            return const ImportedSession(nativeId: 'alpha-imp');
          })
        : null;
    final (info, c) = await limited();
    await c.switchLead('beta', run: true);
    await turn(d('beta').latest!, 'b1', 'Wrote the tests.');
    d('alpha').attachFails = true;
    final outcome = await c.switchLead('alpha', run: true);
    expect((outcome.path, outcome.why), (LeadPath.imported, 'That conversation is gone.'));
    expect(d('alpha').specs, hasLength(1));
    final sent = d('alpha').conversations['alpha-imp']!.sent.single;
    expect(sent, endsWith(carryOnMessage('Beta')));
    expect(sent, isNot(contains(handoffOpen)));
    expect(infoOf(info.id).conversationId, 'alpha-imp');
    expect(
      transcriptOf(info.id).items.whereType<NoticeItem>().map((n) => n.message),
      contains(
        "Alpha couldn't reopen its earlier conversation (That conversation is gone.); "
        'it got a copy of the conversation in its own format.',
      ),
    );
  });

  test('a CLI that says its conversation is gone is not reopened', () async {
    final (info, c) = await limited();
    await c.switchLead('beta', run: true);
    await turn(d('beta').latest!, 'b1', 'Wrote the tests.');
    d('alpha').problem = 'Alpha no longer has that conversation.';
    final outcome = await c.switchLead('alpha', run: true);
    expect((outcome.kind, outcome.path), (HandoffKind.full, LeadPath.fresh));
    expect(outcome.why, 'Alpha no longer has that conversation.');
    expect(d('alpha').attached, isEmpty);
    expect(infoOf(info.id).conversationId, 'alpha-c2');
  });

  test('the session and its timeline survive a restart', () async {
    final (info, c) = await limited();
    await c.switchLead('beta', run: true);
    await turn(d('beta').latest!, 'b1', 'Picked it up.');
    container.dispose();
    container = make();
    await open(info.id);
    await pumpEventQueue();
    final items = transcriptOf(info.id).items;
    final shown = [
      for (final i in items)
        switch (i) {
          AgentText(:final text) => text,
          NoticeItem(:final message) => message,
          UserTurn(:final lead) => 'user@$lead',
          _ => '',
        },
    ].where((s) => s.isNotEmpty).toList();
    expect(shown, [
      'user@Alpha',
      'Added the toggle.',
      'You hit your 5-hour limit.',
      'EveryAI briefing',
      'Handoff to Beta',
      'user@Beta',
      'Picked it up.',
    ]);
  });

  test('a switch that fails leaves the old lead its token and briefing', () async {
    final (info, c) = await limited();
    final briefing = File('${tmp.path}/data/driver-sessions/${info.id}/briefing/$sessionFileName');
    final before = briefing.readAsStringSync();
    expect(host.live[info.id], {'tok1'});
    d('beta').startFails = true;
    final outcome = await c.switchLead('beta', run: true);
    expect(outcome.failed, isTrue);
    final now = infoOf(info.id);
    expect((now.harness, now.conversationId), ('alpha', 'alpha-c1'));
    expect(now.leads, isEmpty);
    // Alpha still reaches EveryAI; only Beta's token went.
    expect(host.live[info.id], {'tok1'});
    expect(host.revokedSessions, isEmpty);
    expect(briefing.readAsStringSync(), before);
    expect(d('alpha').latest!.closed, isFalse);
  });

  test('messages and edits during a switch wait for the new lead', () async {
    final (info, c) = await limited();
    final gate = d('beta').startGate = Completer<void>();
    final switching = c.switchLead('beta', run: true);
    await pumpEventQueue();
    expect(container.read(codeSessionProvider(info.id)).switching, isTrue);
    await c.send('Please also update the README');
    await c.steer('And the changelog');
    expect((await c.compact()).kind, CompactKind.busy);
    expect(d('alpha').latest!.sent.where((m) => m.contains('README') || m.contains('changelog')), isEmpty);
    expect(container.read(codeSessionProvider(info.id)).queued, hasLength(2));
    gate.complete();
    expect((await switching).kind, HandoffKind.full);
    final b = d('beta').latest!;
    expect(b.sent.single, isNot(contains('README')));
    expect(container.read(codeSessionProvider(info.id)).switching, isFalse);
    // Beta's first turn ends; the queued messages follow, one per turn.
    await turn(b, 'b1', 'Picked it up.');
    expect(b.sent.last, endsWith('Please also update the README'));
  });

  test('a busy session switches only once it has stopped', () async {
    final info = await start();
    final c = await open(info.id);
    final a = d('alpha').latest!..add(stateEvent('r1', ExecutionStatus.running));
    await pumpEventQueue();
    expect((await c.switchLead('beta', run: false)).busy, isTrue);
    expect(d('beta').specs, isEmpty);
    a.onInterrupt = [stateEvent('r2', ExecutionStatus.idle)];
    final outcome = await c.switchLead('beta', run: false, stopFirst: true);
    expect(outcome.failed || outcome.busy, isFalse);
    expect(a.interrupts, 1);
    expect(infoOf(info.id).harness, 'beta');
  });

  test("an outside lead's / command goes through as is: no mode note, no handoff; refused while busy", () async {
    final info = await start();
    final c = await open(info.id);
    final a = d('alpha').latest!;
    await turn(a, 'a1', 'Added the toggle.');
    sessions().update(infoOf(info.id).copyWith(pendingHandoff: '<everyai-handoff>…</everyai-handoff>'));
    final sentBefore = [...a.sent];
    expect(await c.runNativeCommand('review', 'x'), isNull);
    expect(a.ran, ['review|x']);
    expect(a.sent, sentBefore);
    expect(infoOf(info.id).pendingHandoff, isNotEmpty);

    a.add(stateEvent('a2-s', ExecutionStatus.running));
    await pumpEventQueue();
    expect(await c.runNativeCommand('init', ''), contains('working'));
    expect(a.ran, ['review|x']);
  });

  group('native modes', () {
    const modes = [
      NativeMode(id: 'careful', label: 'Careful', policy: AgentMode.ask),
      NativeMode(id: 'planner', label: 'Planner', policy: AgentMode.plan),
      NativeMode(id: 'wild', label: 'Wild', policy: AgentMode.fullAuto, blocked: 'Not offered.'),
    ];

    Future<(CodeSessionInfo, CodeSessionController, FakeLeadSession)> withModes() async {
      final info = await start();
      final c = await open(info.id);
      final a = d('alpha').latest!;
      await turn(a, 'a1', 'Added the toggle.');
      a.modeFeed.set(modes: modes, current: 'careful');
      await pumpEventQueue();
      return (info, c, a);
    }

    test('a pick by name sets its policy, is kept with the session, and no EveryAI mode note goes out', () async {
      final (info, c, a) = await withModes();
      final state = container.read(codeSessionProvider(info.id));
      expect(state.nativeModes, modes);
      expect(state.nativeMode, 'careful');
      expect(await c.setNativeMode('planner'), isNull);
      expect(a.picked, ['planner']);
      expect(container.read(codeSessionProvider(info.id)).mode, AgentMode.plan);
      expect((infoOf(info.id).mode, infoOf(info.id).nativeMode), (AgentMode.plan, 'planner'));
      await c.send('Now plan the settings page.');
      expect(a.sent.last, 'Now plan the settings page.');
      expect(a.modes, isEmpty);
    });

    test('our modes map to its own: the nearest that asks as much, else a notice and no change', () async {
      final (info, c, a) = await withModes();
      await c.setMode(AgentMode.autoEdit);
      expect(a.picked, ['careful']);
      a.modeFeed.set(modes: [modes.first, modes.last]);
      await pumpEventQueue();
      await c.setMode(AgentMode.plan);
      expect(a.picked, ['careful']);
      expect(container.read(codeSessionProvider(info.id)).mode, AgentMode.ask);
      expect(transcriptOf(info.id).items.whereType<NoticeItem>().last.message, 'Alpha has no Plan mode.');
    });
  });

  test('leaving the EveryAI harness stops its background forks, once the user agrees', () async {
    CodeSessionController.liveAfter = Duration.zero;
    // Not about the processes a Stop ends: the real table walk (ps + lsof, seconds on a loaded machine) only made the
    // test slow enough for the usage read below to land while EveryAI still led.
    CodeSessionController.killProcesses = ({
      required tag,
      required workingDir,
      required ownsDir,
      workflows = false,
    }) async => const Ended(<int>[]);
    addTearDown(() => CodeSessionController.killProcesses = killSessionProcesses);
    final everyai = d(everyaiHarnessName);
    // The lead left a fork working in the background; its turn has ended.
    everyai.conversations['e1'] = FakeLeadSession(
      id: 'e1',
      replays: true,
      history: [
        userMessageEvent('u1', 'Add dark mode'),
        const ActionCall(id: 't1', raw: {}, toolName: taskTool, toolCallId: 'tc1', action: {'run_in_background': true}),
        ToolResult(
          id: 't1-r',
          raw: const {},
          actionId: 't1',
          toolName: taskTool,
          outcome: ToolOutcome.ok,
          observation: {
            'content': [
              {'type': 'text', 'text': backgroundStarted('k1').text},
            ],
          },
        ),
        agentMessageEvent('a1', 'A fork is on it.'),
        stateEvent('s1-idle', ExecutionStatus.idle),
      ],
    );
    everyai.conversations['e2'] = FakeLeadSession(id: 'e2', replays: true);
    CodeSessionInfo info(String id, String conversation, {String? parent}) => CodeSessionInfo(
      id: id,
      projectId: 'p1',
      title: id == 's1' ? 'Dark mode' : 'Fork',
      conversationId: conversation,
      model: 'anthropic/claude-sonnet-5.5',
      mode: AgentMode.ask,
      workingDir: project.path,
      createdAt: DateTime(2026),
      harness: everyaiHarnessName,
      parentId: parent,
      parentCallId: parent == null ? '' : 't1',
    );
    prefs['code.sessions'] = jsonEncode([info('s1', 'e1').toJson(), info('k1', 'e2', parent: 's1').toJson()]);
    container.dispose();
    container = make();
    final c = await open('s1');
    await whenValue(container, codeSessionProvider('k1').select((s) => s.connected), (bool on) => on);
    expect(c.leaveStopsChildren('beta'), isTrue);
    // Without the user's yes nothing changes.
    expect((await c.switchLead('beta', run: false)).busy, isTrue);
    expect(infoOf('s1').harness, everyaiHarnessName);
    final fork = everyai.conversations['e2']!;
    expect(fork.interrupts, 0);
    final outcome = await c.switchLead('beta', run: false, stopFirst: true);
    expect(outcome.failed, isFalse);
    expect(infoOf('s1').harness, 'beta');
    // While EveryAI led, its usage reading may reach the backend (its debounce can fire on a slow run); from here on
    // the tearDown's check holds: the outside lead reaches nothing.
    _sent.clear();
    expect(fork.interrupts, greaterThan(0));
    expect(c.leaveStopsChildren(everyaiHarnessName), isFalse);
  });

  test('deleting a switched session drops its timeline and briefings', () async {
    final (info, c) = await limited();
    await c.switchLead('beta', run: true);
    final dir = await sessions().timelineDir(info.id);
    expect(Directory(dir).existsSync(), isTrue);
    await sessions().remove(info.id);
    expect(Directory(dir).existsSync(), isFalse);
    expect(host.revokedSessions, contains(info.id));
  });

  group('the switch picker and the default handoff', () {
    test('with a default, a limit moves on to it by itself and says so', () async {
      CodeSessionController.liveAfter = Duration.zero;
      container.read(codeLeadProvider.notifier).chooseHandoff('beta');
      final (info, c) = await limited();
      await handedOff(info.id, 'beta');
      final first = d('beta').specs.single.initialMessage!;
      expect(first, contains('$handoffOpen from="alpha" kind="full">'));
      expect(first, endsWith(carryOnMessage('Alpha')));
      final notice = transcriptOf(info.id).items.whereType<NoticeItem>().singleWhere((n) => n.handedOffFrom.isNotEmpty);
      expect(notice.message, 'Your Alpha limit ran out; continuing on Beta');
      expect(notice.handedOffFrom, 'alpha');
      expect(c.limitPick, isNull);
      // Change opens the picker again, without the one that ran out; Keep closes it.
      c.changeHandoff('alpha');
      final pick = c.limitPick!;
      expect((pick.change, pick.ranOut, pick.limit.message), (true, 'alpha', 'You hit your 5-hour limit.'));
      c.keepLead();
      expect(c.limitPick, isNull);
    });

    test('a limit replayed on reopen does not hand off', () async {
      final (info, _) = await limited();
      container.dispose();
      CodeSessionController.liveAfter = Duration.zero;
      container = make();
      container.read(codeLeadProvider.notifier).chooseHandoff('beta');
      final c = await open(info.id);
      // More of the old conversation, and a fresh event, once it is live.
      await pumpEventQueue();
      d('alpha').latest!.add(stateEvent('a3-s', ExecutionStatus.error));
      await pumpEventQueue();
      expect(infoOf(info.id).harness, 'alpha');
      expect(d('beta').specs, isEmpty);
      expect(c.limitPick?.ranOut, 'alpha');
    });

    test('the default running out too asks instead of looping', () async {
      CodeSessionController.liveAfter = Duration.zero;
      container.read(codeLeadProvider.notifier).chooseHandoff('beta');
      final (info, c) = await limited();
      await handedOff(info.id, 'beta');
      final b = d('beta').latest!;
      await turn(b, 'b1', 'Picked it up.');
      b
        ..add(usageLimitEvent('b2-limit', 'Beta is out too.'))
        ..add(stateEvent('b2-s', ExecutionStatus.error));
      expect(await handoffProblem(info.id), 'Your default handoff, Beta, is the one that ran out.');
      expect(infoOf(info.id).harness, 'beta');
      expect(c.limitPick?.ranOut, 'beta');
      expect(d('alpha').specs, hasLength(1));
    });
  });

  group('native import', () {
    test('an imported conversation is reopened and gets only the carry-on', () async {
      final written = <NativeImportSource>[];
      importerFor = (h) => h == 'beta'
          ? _FakeImporter('beta', (src) {
              written.add(src);
              d('beta').conversations['nat-1'] = FakeLeadSession(id: 'nat-1', replays: true);
              return const ImportedSession(nativeId: 'nat-1', note: 'Imported 1 turn into Beta');
            })
          : null;
      final (info, c) = await limited();
      final outcome = await c.switchLead('beta', run: true);
      expect(outcome.failed, isFalse);
      expect(d('beta').specs, isEmpty);
      expect(d('beta').attached, ['nat-1']);
      final sent = d('beta').latest!.sent.single;
      expect(sent, endsWith(carryOnMessage('Alpha')));
      expect(sent, isNot(contains(handoffOpen)));
      expect(infoOf(info.id).conversationId, 'nat-1');
      expect(written.single.stints.map((s) => s.lead), ['Alpha']);
      expect(written.single.handoff.fromHarness, 'alpha');
      expect(
        transcriptOf(info.id).items.whereType<NoticeItem>().map((n) => n.message),
        contains('Imported 1 turn into Beta'),
      );
      // The facts are kept for a later return.
      expect(await loadHandoffs(await sessions().timelineDir(info.id)), hasLength(1));
    });

    test('a cut-off turn goes with the carry-on to an imported conversation', () async {
      importerFor = (h) => h == 'beta'
          ? _FakeImporter('beta', (src) {
              d('beta').conversations['nat-1'] = FakeLeadSession(id: 'nat-1', replays: true);
              return const ImportedSession(nativeId: 'nat-1');
            })
          : null;
      final info = await start();
      final c = await open(info.id);
      d('alpha').latest!
        ..add(userMessageEvent('a1-u', 'Add dark mode'))
        ..add(usageLimitEvent('a1-limit', 'You hit your 5-hour limit.'))
        ..add(stateEvent('a1-s', ExecutionStatus.error));
      await pumpEventQueue();
      await c.switchLead('beta', run: true);
      final sent = d('beta').latest!.sent.single;
      expect(sent, contains('</cut-turn>'));
      expect(sent, endsWith(carryOnMessage('Alpha', cut: true)));
    });

    test('no import, or a failed one, falls back to the facts handoff', () async {
      for (final importer in [
        _FakeImporter('beta', (_) => null),
        _FakeImporter('beta', (_) => throw const FileSystemException('read-only')),
        // Written, but the CLI can't open it.
        _FakeImporter('beta', (_) => const ImportedSession(nativeId: 'missing')),
      ]) {
        importerFor = (h) => h == 'beta' ? importer : null;
        final (info, c) = await limited();
        await c.switchLead('beta', run: true);
        expect(infoOf(info.id).harness, 'beta');
        expect(d('beta').specs.last.initialMessage!, contains('$handoffOpen from="alpha" kind="full">'));
      }
    });
  });
}

final class _FakeImporter implements NativeImporter {
  _FakeImporter(this.harness, this._write);

  @override
  final String harness;
  final ImportedSession? Function(NativeImportSource) _write;

  @override
  Future<ImportedSession?> write(NativeImportSource source) async => _write(source);
}
