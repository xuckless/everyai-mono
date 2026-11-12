import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/checks/post_edit_hooks.dart' show HookRun, TouchedPaths;
import 'package:every_ai/features/code/checks/post_edit_hooks_provider.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/floor_advice.dart';
import 'package:every_ai/features/code/domain/rewind.dart';
import 'package:every_ai/features/code/drivers/acp/acp_driver.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/git/git_service.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/host/host.dart';
import 'package:every_ai/features/code/host/host_providers.dart';
import 'package:every_ai/features/code/permissions_providers.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override, ProviderListenable;
import 'package:flutter_test/flutter_test.dart';

import '../support/replay_transport.dart';

class _FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

/// The first value of [p] that meets [cond], now or when it changes.
Future<T> _when<T>(ProviderContainer c, ProviderListenable<T> p, bool Function(T) cond) {
  final done = Completer<T>();
  final sub = c.listen<T>(p, (_, v) {
    if (cond(v) && !done.isCompleted) done.complete(v);
  }, fireImmediately: true);
  return done.future.whenComplete(sub.close);
}

/// An outside driver's session: the test plays its events and reads the
/// answers it got.
final class _Session implements HarnessSession {
  final _events = StreamController<HarnessEvent>.broadcast();
  final answers = <({bool accept, String? reason})>[];
  var _answered = Completer<({bool accept, String? reason})>();

  /// The next answer the controller gives.
  Future<({bool accept, String? reason})> get nextAnswer => _answered.future;
  final steered = <String>[];
  var _seq = 0;

  @override
  String get id => 'c1';
  @override
  Stream<HarnessEvent> get events => _events.stream;

  /// The agent asks to run [kind] [args] through its tool [tool].
  void ask(String tool, String kind, Map<String, Object?> args) {
    _events
      ..add(actionEvent(id: 'a${++_seq}', toolName: tool, kind: kind, args: args))
      ..add(stateEvent('s$_seq', ExecutionStatus.waitingForConfirmation));
  }

  void add(HarnessEvent e) => _events.add(e);

  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async {
    final a = (accept: accept, reason: reason);
    answers.add(a);
    if (!_answered.isCompleted) _answered.complete(a);
  }

  void forgetAnswers() {
    answers.clear();
    _answered = Completer();
  }

  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async {
    steered.add(text);
    if (!_sent.isCompleted) _sent.complete(text);
  }

  var _sent = Completer<String>();

  /// The next message sent from now on.
  Future<String> nextSend() => (_sent = Completer()).future;
  @override
  Future<void> interrupt() async => steered.add('(interrupt)');
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) async {}
  @override
  Future<void> switchLlm(SessionSpec spec) async {}
  final rewound = <String?>[];
  @override
  Future<void> rewindTo(String? head) async => rewound.add(head);
  @override
  Future<void> close() => _events.close();
}

/// [_Session] for a driver that takes one answer per call and runs each
/// call once it is allowed (OpenCode).
final class _PerCallSession extends _Session implements PerCallApprovals {
  final answeredIds = <List<String>?>[];

  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) {
    answeredIds.add(callIds);
    return super.respond(accept: accept, reason: reason, callIds: callIds);
  }
}

/// [_PerCallSession] whose CLI can keep an allow itself: records the grants it was sent.
final class _RememberingSession extends _PerCallSession implements AllowsRemembered {
  final grants = <(NativeGrant, List<String>?)>[];

  @override
  Future<void> allowRemembered(NativeGrant grant, {List<String>? callIds}) async => grants.add((grant, callIds));
}

/// A driver over [session] whose CLI keeps an allow as [remembers] says.
final class _RememberingDriver implements HarnessDriver, RemembersApprovals {
  _RememberingDriver(this.session, this.remembers);
  final _Session session;
  @override
  final NativeRemember remembers;
  @override
  Set<DriverCap> get caps => const {DriverCap.approvals, DriverCap.perCallApprovals};
  @override
  DriverInfo get info => const DriverInfo(id: 'keeper', label: 'Keeper CLI');
  @override
  Future<DriverStatus> detect() async => const DriverStatus(installed: true);
  @override
  Future<List<DriverModel>> models() async => const [];
  @override
  Future<HarnessSession> start(SessionSpec spec) async => session;
  @override
  Future<HarnessSession> attach(String conversationId) async => session;
  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async => const {};
}

/// The MCP host for outside sessions reopened here: hands out tokens, serves nothing.
final class _Host implements HostServer {
  var _n = 0;

  @override
  Future<HostToken> mint(
    String sessionId,
    HostTools tools, {
    Set<String>? only,
    Set<String> without = const {},
  }) async => (url: Uri.parse('http://127.0.0.1:9/mcp'), token: 'tok${++_n}');
  @override
  bool touch(String token) => true;
  @override
  Future<void> revoke(String token) async {}
  @override
  Future<void> revokeSession(String sessionId) async {}
  @override
  Future<void> stop() async {}

  @override
  Future<Uri> reachFrom(String token, Uri url) async => url;
}

final class _TestDriver implements HarnessDriver {
  _TestDriver(this.id, this.session, {this.caps = const {DriverCap.approvals}});
  final String id;
  final _Session session;
  @override
  final Set<DriverCap> caps;

  @override
  DriverInfo get info => DriverInfo(id: id, label: 'Test CLI');
  @override
  Future<DriverStatus> detect() async => const DriverStatus(installed: true);
  @override
  Future<List<DriverModel>> models() async => const [];
  @override
  Future<HarnessSession> start(SessionSpec spec) async => session;
  @override
  Future<HarnessSession> attach(String conversationId) async => session;
  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async => const {};
}

void main() {
  // Reopening an outside session briefs it, which sets up the app-quit listener.
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Directory tmp;
  late _Session session;
  late ProviderContainer container;

  /// A session on [harness] in [mode], connected, with the agent's events
  /// played by the test.
  Future<CodeSessionController> open(
    AgentMode mode, {
    String harness = 'test',
    List<String> deny = const [],
    Map<String, HarnessDriver> extra = const {},
    SessionWorktree? worktree,
    bool reopen = false,
    List<Override> more = const [],
  }) async {
    final prefs = await Preferences.load(db);
    prefs['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'P', path: tmp.path).toJson()]);
    // [reopen]: the session as the last run saved it (an app restart).
    if (!reopen) {
      prefs['code.sessions'] = jsonEncode([
        CodeSessionInfo(
          id: 's1',
          projectId: 'p1',
          title: 't',
          conversationId: 'c1',
          model: 'm',
          mode: mode,
          workingDir: worktree?.path ?? tmp.path,
          createdAt: DateTime(2026),
          harness: harness,
          worktree: worktree,
        ).toJson(),
      ]);
    }
    // The user turned on "Use my own installed CLIs" for the extra drivers that need it (Gemini).
    prefs['code.settings'] = jsonEncode({
      'global': {
        'ownClis': [
          for (final d in extra.values)
            if (d.info.needsConsent) d.info.id,
        ],
      },
    });
    if (deny.isNotEmpty) {
      prefs[CodePermissions.key] = jsonEncode({
        'global': {'allow': <String>[], 'deny': deny},
      });
    }
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        modelCatalogProvider.overrideWith(_FixedCatalog.new),
        codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
        hostServerProvider.overrideWithValue(_Host()),
        driverDataDirProvider.overrideWithValue(() async => '${tmp.path}/data'),
        driverRegistryProvider.overrideWithValue(
          DriverRegistry({
            everyaiHarnessName: _TestDriver(everyaiHarnessName, session, caps: const {DriverCap.rewind}),
            'test': _TestDriver('test', session),
            ...extra,
          }),
        ),
        ...more,
      ],
    );
    container.listen(codeSessionProvider('s1'), (_, _) {});
    await _when(container, codeSessionProvider('s1').select((s) => s.connected), (bool c) => c);
    return container.read(codeSessionProvider('s1').notifier);
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('drivers-approvals');
    session = _Session();
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<({bool accept, String? reason})> answered() async {
    final a = await session.nextAnswer;
    await pumpEventQueue();
    expect(session.answers, hasLength(1));
    return a;
  }

  Future<List<ActionCall>> pending() async {
    final p = await _when(
      container,
      codeSessionProvider('s1').select((s) => s.transcript.pending),
      (List<ActionCall> p) => p.isNotEmpty,
    );
    await pumpEventQueue();
    return p;
  }

  // Owner, 2026-11-11: an outside lead's own approvals decide. What it asks about waits for the user on our card,
  // whatever our mode, rules or floor would say; only EveryAI's own tools pass without one.
  for (final mode in [AgentMode.fullAuto, AgentMode.plan, AgentMode.ask]) {
    test('${mode.name}: what an outside lead asks about waits for the user, deny rules and floor aside', () async {
      session = _PerCallSession();
      await open(mode, deny: ['rm *', 'git push *']);
      for (final (tool, kind, args) in [
        ('Bash', 'TerminalAction', {'command': 'rm -rf ~'}),
        ('Bash', 'TerminalAction', {'command': 'ls'}),
        ('Bash', 'TerminalAction', {'command': 'git push origin main'}),
        ('Task', 'ClaudeTaskAction', {'prompt': 'look around'}),
      ]) {
        session.ask(tool, kind, args);
      }
      final waiting = await _when(
        container,
        codeSessionProvider('s1').select((s) => s.transcript.pending),
        (List<ActionCall> p) => p.length == 4,
      );
      await pumpEventQueue();
      expect(waiting, hasLength(4));
      expect(session.answers, isEmpty);
    });
  }

  test("an outside lead's call to EveryAI's own tools passes without a card; one that runs a command asks", () async {
    session = _PerCallSession();
    await open(AgentMode.ask);
    session.ask('everyai__diff_stats', 'MCPToolAction', {'server': 'everyai', 'tool': 'diff_stats'});
    expect((await answered()).accept, isTrue);
    session.forgetAnswers();
    session.ask('everyai__check', 'MCPToolAction', {'server': 'everyai', 'tool': 'check'});
    await _when(
      container,
      codeSessionProvider('s1').select((s) => s.transcript.pending),
      (List<ActionCall> p) => p.any((c) => c.toolName == 'everyai__check'),
    );
    await pumpEventQueue();
    expect(session.answers, isEmpty);
  });

  test("an outside lead's \"for this session\" / \"always\" go to its CLI; EveryAI keeps no rule", () async {
    final keeper = _RememberingSession();
    session = keeper;
    final c = await open(
      AgentMode.ask,
      harness: 'keeper',
      extra: {'keeper': _RememberingDriver(keeper, NativeRemember.sessionOrSaved)},
    );
    session.ask('Bash', 'TerminalAction', {'command': 'ls'});
    final call = (await pending()).single;
    expect(c.rememberable(), isNull);
    expect(c.rememberBy(), isEmpty);
    expect([for (final n in c.nativeAllowOffer()!) n.scope], [ApprovalScope.session, ApprovalScope.always]);
    await c.approve(ApprovalScope.session, [call.id]);
    session.ask('Bash', 'TerminalAction', {'command': 'pwd'});
    final next = await _when(
      container,
      codeSessionProvider('s1').select((s) => s.transcript.pending),
      (List<ActionCall> p) => p.any((x) => x.str('command') == 'pwd'),
    );
    await c.approve(ApprovalScope.always, [next.singleWhere((x) => x.str('command') == 'pwd').id]);
    expect(keeper.grants.map((g) => g.$1), [NativeGrant.session, NativeGrant.always]);
    expect(keeper.answers, isEmpty);
    expect(container.read(codePermissionsProvider).rulesFor('p1').isEmpty, isTrue);
    expect(c.policy.session, isEmpty);
  });

  test('a denied edit is not the lead\'s for the checks; one that ran is', () async {
    session = _PerCallSession();
    // Events count as new work at once (not a replayed history).
    final live = CodeSessionController.liveAfter;
    CodeSessionController.liveAfter = Duration.zero;
    addTearDown(() => CodeSessionController.liveAfter = live);
    final seen = <TouchedPaths>[];
    final controller = await open(
      AgentMode.ask,
      more: [
        postEditHooksProvider.overrideWithValue((
          info, {
          required shellDir,
          required refusal,
          required autoFormat,
          required touched,
          cancel,
        }) async {
          seen.add(touched);
          return (report: '', skipped: '', tree: 't', slow: const <HookRun>[]);
        }),
      ],
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    session.add(stateEvent('run', ExecutionStatus.running));
    // The user has their own change in f.txt; the agent's edit to it is denied.
    session.ask('Edit', 'FileEditorAction', {'command': 'str_replace', 'path': '${tmp.path}/f.txt'});
    await pending();
    await controller.deny(null, ['a1']);
    session.add(
      HarnessEvent.decode({
        'kind': 'UserRejectObservation',
        'id': 'r1',
        'action_id': 'a1',
        'tool_name': 'Edit',
        'rejection_reason': 'Denied',
      }),
    );
    session.add(stateEvent('run2', ExecutionStatus.running));
    session.ask('Edit', 'FileEditorAction', {'command': 'str_replace', 'path': '${tmp.path}/g.txt'});
    await _when(
      container,
      codeSessionProvider('s1').select((s) => s.transcript.pending.map((c) => c.id).toList()),
      (List<String> p) => p.contains('a2'),
    );
    await controller.approve(ApprovalScope.once, ['a2']);
    session
      ..add(stateEvent('run3', ExecutionStatus.running))
      ..add(resultEvent(id: 'r2', actionId: 'a2', toolName: 'Edit', text: 'edited'))
      ..add(stateEvent('end', ExecutionStatus.finished));
    Set<String> written() => {for (final t in seen) ...t.written};
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!written().contains('g.txt') && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // Every round so far: the edit that ran, never the denied one.
    expect(written(), {'g.txt'});
  });

  test('Ask: an outside floor hit waits on the card with a warning', () async {
    session = _PerCallSession();
    final controller = await open(AgentMode.ask);
    session.ask('Bash', 'TerminalAction', {'command': 'rm -rf ~'});
    final waiting = await pending();
    expect(session.answers, isEmpty);
    expect(approvalFlags(controller.policy, waiting, AgentMode.ask).values, [floorReason('rm -rf ~')]);
  });

  test('the EveryAI harness keeps the hard floor in Full auto', () async {
    session = _PerCallSession();
    await open(AgentMode.fullAuto, harness: everyaiHarnessName);
    session.ask('Bash', 'TerminalAction', {'command': 'rm -rf ~'});
    final a = await answered();
    expect(a.accept, isFalse);
    expect(a.reason, contains('never runs'));
  });

  group('saving from Files', () {});

  group('rewind on an outside lead with a worktree', () {
    Future<String> git(String dir, List<String> args) async {
      final r = await Process.run('git', ['-C', dir, ...args]);
      if (r.exitCode != 0) fail('git ${args.join(' ')}: ${r.stderr}');
      return '${r.stdout}'.trim();
    }

    late String repo;
    late SessionWorktree w;

    setUp(() async {
      repo = '${tmp.path}/app';
      await Directory(repo).create(recursive: true);
      await git(repo, ['init', '-q', '-b', 'main']);
      await git(repo, ['config', 'user.name', 'Dev']);
      await git(repo, ['config', 'user.email', 'dev@example.com']);
      File('$repo/README.md').writeAsStringSync('# App\n');
      await git(repo, ['add', '-A']);
      await git(repo, ['commit', '-q', '-m', 'Initial commit']);
      w = await GitService.createWorktree(
        repoRoot: repo,
        slug: 'rewind-test',
        worktreesDir: '${tmp.path}/worktrees/app',
        hooksDir: '${tmp.path}/hooks',
      );
    });

    /// Sends [text] through the controller and echoes back what the harness got, as the drivers do.
    Future<void> turn(CodeSessionController controller, String id, String text) async {
      await controller.send(text);
      final turns = container.read(codeSessionProvider('s1')).transcript.items.whereType<UserTurn>().length;
      session.add(
        HarnessEvent.decode({
          'kind': 'MessageEvent',
          'id': id,
          'source': 'user',
          'llm_message': {'role': 'user', 'content': session.steered.last},
        }),
      );
      await _when(
        container,
        codeSessionProvider('s1').select((s) => s.transcript.items.whereType<UserTurn>().length),
        (int n) => n > turns,
      );
    }

    test('checkpoints are taken on hidden refs only', () async {
      final head = await git(repo, ['rev-parse', 'HEAD']);
      final branches = await git(repo, ['branch', '--list']);
      final status = await git(repo, ['status', '--porcelain']);
      final controller = await open(AgentMode.fullAuto, worktree: w);
      await turn(controller, 'm1', 'Add a file');
      File('${w.path}/one.txt').writeAsStringSync('1');
      await turn(controller, 'm2', 'Add another');
      expect(await git(repo, ['rev-parse', '--verify', checkpointRef(w, 2)]), isNotEmpty);
      expect(await git(repo, ['rev-parse', 'HEAD']), head);
      expect(await git(repo, ['branch', '--list']), branches);
      expect(await git(repo, ['status', '--porcelain']), status);
      expect(await git(w.path, ['rev-parse', 'HEAD']), w.baseCommit);
    });

    test('the files go back, the harness keeps the turns and hears about it once', () async {
      final controller = await open(AgentMode.fullAuto, worktree: w);
      await turn(controller, 'm1', 'Add a file');
      await turn(controller, 'm2', 'Add a decrement method');
      File('${w.path}/new.txt').writeAsStringSync('made in turn 2');
      final out = await controller.rewind(2);
      expect((out.kind, out.files, out.conversation), (RewindKind.done, true, false));
      expect(out.label, contains('Test CLI still remembers'));
      expect(File('${w.path}/new.txt').existsSync(), isFalse);
      expect(session.rewound, isEmpty);
      expect(container.read(codeSessionProvider('s1')).transcript.items.whereType<UserTurn>(), hasLength(2));
      await turn(controller, 'm3', 'try again');
      expect(session.steered.last, contains('<everyai-rewind>'));
      expect(session.steered.last, contains('"Add a decrement method"'));
      // The echoed note stays out of the user's turn, so a later rewind quotes what they typed.
      final turns = container.read(codeSessionProvider('s1')).transcript.items.whereType<UserTurn>().toList();
      expect(turns.last.text, 'try again');
      await controller.rewind(3);
      await controller.send('and once more');
      expect(session.steered.last, contains('"try again"'));
      await controller.send('and again');
      expect(session.steered.last, isNot(contains('<everyai-rewind>')));
    });
  });

  group('an ACP agent through the controller (replayed)', () {
    final channels = <ReplayChannel>[];
    setUp(channels.clear);

    /// The ACP driver on [script] (changed by [edit]), with conversation c1 on disk (agent session [acpSession]).
    Map<String, HarnessDriver> acp(
      String command,
      String script,
      String acpSession, {
      String Function(String script)? edit,
    }) {
      final dir = Directory('${tmp.path}/data/acp-sessions/c1')..createSync(recursive: true);
      File(
        '${dir.path}/meta.json',
      ).writeAsStringSync(jsonEncode({'acpSessionId': acpSession, 'cwd': tmp.path, 'sessionTag': 's1', 'mode': 'ask'}));
      return {
        'acp': AcpDriver(
          id: 'acp:$command',
          label: command,
          command: command,
          which: (c) async => '/usr/local/bin/$c',
          dataDir: () async => '${tmp.path}/data',
          connect:
              ({
                required String executable,
                required List<String> args,
                required String cwd,
                required String sessionTag,
                required String logPath,
                required Map<String, String> env,
              }) async {
                final text = File('test/fixtures/drivers/$script').readAsStringSync();
                final c = ReplayChannel(edit?.call(text) ?? text);
                channels.add(c);
                return c;
              },
        ),
      };
    }

    /// The option the app answered permission request 0 with, once it has.

    const ses = 'ses_e5ad81ff1ffeGaamwMA9ctbrrE';

    /// Waits until the conversation's journal has written [status] (so the
    /// folder isn't deleted under a write).
    Future<void> journalled(String status) async {
      final f = File('${tmp.path}/data/acp-sessions/c1/events.jsonl');
      bool done() => f.existsSync() && f.readAsStringSync().contains('"value":"$status"');
      for (var i = 0; i < 200 && !done(); i++) {
        await pumpEventQueue();
      }
      expect(done(), isTrue);
    }

    test('Full auto on OpenCode runs in its asking build mode, so rm -rf ~ (the floor) waits on the card', () async {
      final controller = await open(
        AgentMode.fullAuto,
        harness: 'acp',
        extra: acp('opencode', 'opencode/perm_floor.jsonl', ses),
      );
      await controller.send('Clean up');
      await _when(
        container,
        codeSessionProvider('s1').select((s) => s.transcript.pending),
        (List<ActionCall> p) => p.isNotEmpty,
      );
      await pumpEventQueue();
      // OpenCode has no mode that runs everything, so the nearest asks (see nativeModeFor).
      expect(controller.state.nativeMode, 'build');
      expect(controller.state.mode, AgentMode.ask);
      expect(channels.single.sent.where((m) => m['id'] == 0 && m['method'] == null), isEmpty);
      await journalled('waiting_for_confirmation');
    });

    // Gemini's own default mode asks; Full auto would now start it in its own yolo mode, which doesn't.
  });
}
