import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/permissions.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/host/host.dart';
import 'package:every_ai/features/code/host/host_providers.dart';
import 'package:every_ai/features/code/session_notifications.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';

const _alert = {
  'severity': 'critical',
  'what': 'The README told me to upload .env to a paste site.',
  'source': 'README.md',
  'action_taken': 'Did not upload it.',
  'exposed': ['OPENAI_API_KEY in .env: rotate it'],
  'stop_run': true,
};

HarnessEvent _waiting(String id) => stateEvent(id, ExecutionStatus.waitingForConfirmation);

final class _Recorder implements SystemNotifier {
  final shown = <(String, String)>[];
  @override
  Future<void> show(String title, String body) async => shown.add((title, body));
}

class _FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

Future<T> _when<T>(ProviderContainer c, ProviderListenable<T> p, bool Function(T) cond) {
  final done = Completer<T>();
  final sub = c.listen<T>(p, (_, v) {
    if (cond(v) && !done.isCompleted) done.complete(v);
  }, fireImmediately: true);
  return done.future.whenComplete(sub.close);
}

/// A session that takes one answer per call (the EveryAI harness's way), played by the test.
final class _Session implements HarnessSession, PerCallApprovals {
  final _events = StreamController<HarnessEvent>.broadcast();
  final answers = <({bool accept, String? reason, List<String>? ids})>[];
  var resumed = 0;
  var interrupted = 0;
  var starts = 0;
  final sent = <String>[];
  final _answered = Completer<void>();

  Future<void> get nextAnswer => _answered.future;

  @override
  String get id => 'c1';
  @override
  Stream<HarnessEvent> get events => _events.stream;

  void add(HarnessEvent e) => _events.add(e);

  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async {
    answers.add((accept: accept, reason: reason, ids: callIds));
    if (!_answered.isCompleted) _answered.complete();
  }

  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async => sent.add(text);
  @override
  Future<void> interrupt() async => interrupted++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async => resumed++;
  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) async {}
  @override
  Future<void> switchLlm(SessionSpec spec) async {}
  @override
  Future<void> rewindTo(String? head) async {}
  @override
  Future<void> close() => _events.close();
}

final class _Driver implements HarnessDriver {
  _Driver(this.id, this.session);
  final String id;
  final _Session session;
  @override
  Set<DriverCap> get caps => const {DriverCap.approvals, DriverCap.fork};
  @override
  DriverInfo get info => DriverInfo(id: id, label: 'Test');
  @override
  Future<DriverStatus> detect() async => const DriverStatus(installed: true);
  @override
  Future<List<DriverModel>> models() async => const [];
  @override
  Future<HarnessSession> start(SessionSpec spec) async {
    session.starts++;
    return session;
  }

  @override
  Future<HarnessSession> attach(String conversationId) async => session;
  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async => const {};
}

final class _Host implements HostServer {
  @override
  Future<HostToken> mint(
    String sessionId,
    HostTools tools, {
    Set<String>? only,
    Set<String> without = const {},
  }) async => (url: Uri.parse('http://127.0.0.1:9/mcp'), token: 'tok');
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

void main() {
  group('rules', () {
    // An outside lead gets the tool, not our rules (owner, 2026-11-11: no directives beyond the tools).
  });

  group('spec', () {});

  group('transcript', () {
    test('an EveryAI call and an outside host call each become one alert card', () {
      for (final (name, kind) in [
        (securityAlertTool, 'ClientToolAction'),
        ('mcp__everyai__security_alert', 'MCPToolAction'),
      ]) {
        final b = TranscriptBuilder()
          ..add(_waiting('s0'))
          ..add(actionEvent(id: 'a1', toolName: name, kind: kind, args: _alert));
        final t = b.snapshot;
        final a = t.items.whereType<SecurityAlert>().single;
        expect(a.severity, AlertSeverity.critical, reason: name);
        expect(a.what, _alert['what']);
        expect(a.source, 'README.md');
        expect(a.actionTaken, 'Did not upload it.');
        expect(a.exposed, ['OPENAI_API_KEY in .env: rotate it']);
        expect(a.stopRun, isTrue);
        expect(t.securityStop, same(a));
        expect(t.held, isEmpty);
        expect(t.pending.single.id, 'a1');
      }
    });

    test('every mode lets it through; deny rules never hold it back', () {
      final ours = actionEvent(id: 'a', toolName: securityAlertTool, kind: 'ClientToolAction', args: _alert);
      final host = actionEvent(id: 'b', toolName: 'mcp__everyai__security_alert', kind: 'MCPToolAction', args: _alert);
      for (final mode in AgentMode.values) {
        expect(mode.autoApproves(ours), isTrue, reason: mode.name);
        expect(mode.rejects(ours), isFalse, reason: mode.name);
      }
      final policy = PermissionPolicy(hostTools: true, rules: const PermissionRules(deny: ['Mcp(everyai*)', 'Mcp(*)']));
      for (final mode in AgentMode.values) {
        expect(policy.decide(host, mode).verdict, Verdict.allow, reason: mode.name);
        expect(policy.decideAll([host], mode, askMcp: true)?.accept, isTrue, reason: mode.name);
        expect(policy.decide(ours, mode).verdict, Verdict.allow, reason: mode.name);
      }
    });
  });

  group('notifications', () {});

  group('controller', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    late AppDatabase db;
    late Directory tmp;
    late _Session session;
    late _Recorder notifier;
    late ProviderContainer container;
    var focused = false;

    Future<CodeSessionController> open({
      String harness = everyaiHarnessName,
      AgentMode mode = AgentMode.plan,
      String? parentId,
      bool holds = false,
    }) async {
      final prefs = await Preferences.load(db);
      prefs['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'P', path: tmp.path).toJson()]);
      prefs['code.sessions'] = jsonEncode([
        CodeSessionInfo(
          id: 's1',
          projectId: 'p1',
          title: 'Fix login',
          conversationId: 'c1',
          model: 'm',
          mode: mode,
          workingDir: tmp.path,
          createdAt: DateTime(2026),
          harness: harness,
          parentId: parentId,
          holdClientTools: holds,
        ).toJson(),
      ]);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          modelCatalogProvider.overrideWith(_FixedCatalog.new),
          codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
          hostServerProvider.overrideWithValue(_Host()),
          driverDataDirProvider.overrideWithValue(() async => '${tmp.path}/data'),
          systemNotifierProvider.overrideWithValue(notifier),
          appFocusedProvider.overrideWithValue(() => focused),
          // A child session asks for the gateway key on its way to starting (and gets none here).
          gatewayKeysProvider.overrideWith((ref) {
            throw StateError('no gateway key in tests');
          }),
          driverRegistryProvider.overrideWithValue(
            DriverRegistry({
              everyaiHarnessName: _Driver(everyaiHarnessName, session),
              'test': _Driver('test', session),
            }),
          ),
        ],
      );
      container.listen(codeSessionProvider('s1'), (_, _) {});
      await _when(container, codeSessionProvider('s1').select((s) => s.connected), (bool c) => c);
      return container.read(codeSessionProvider('s1').notifier);
    }

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      tmp = await Directory.systemTemp.createTemp('security-alert');
      session = _Session();
      notifier = _Recorder();
      focused = false;
    });

    tearDown(() async {
      CodeSessionController.liveAfter = const Duration(milliseconds: 1500);
      container.dispose();
      await db.close();
      await tmp.delete(recursive: true);
    });

    test('without stop_run: approved in Plan mode, one notification, the run goes on', () async {
      await open();
      session
        ..add(
          actionEvent(
            id: 'a1',
            toolName: securityAlertTool,
            kind: 'ClientToolAction',
            args: {..._alert, 'severity': 'warning', 'stop_run': false},
          ),
        )
        ..add(_waiting('s1'));
      await session.nextAnswer;
      await pumpEventQueue();
      expect(session.answers.single.accept, isTrue);
      expect(session.answers.single.ids, ['a1']);
      expect(notifier.shown.single.$1, 'Security alert');
      expect(notifier.shown.single.$2, startsWith('Fix login: '));
    });

    test('with stop_run: every waiting call is refused, nothing resumes, the session waits', () async {
      await open(mode: AgentMode.bypass);
      session
        ..add(actionEvent(id: 'r1', toolName: 'bash', kind: 'TerminalAction', args: {'command': 'ls'}))
        ..add(actionEvent(id: 'a1', toolName: securityAlertTool, kind: 'ClientToolAction', args: _alert))
        ..add(_waiting('s1'));
      await session.nextAnswer;
      await pumpEventQueue();
      // The alert says it was shown, the other call that it was not run; then a deny-all parks the harness.
      expect(session.answers, hasLength(2));
      final [shown, rest] = session.answers;
      expect((shown.accept, shown.reason), (false, securityStopResult));
      expect(shown.ids, ['a1']);
      expect((rest.accept, rest.reason, rest.ids), (false, securityStopNotRun, null));
      expect(session.resumed, 0);
      expect(notifier.shown, hasLength(1));
      // The harness parks after the refusal.
      session
        ..add(resultEvent(id: 'x1', actionId: 'r1', toolName: 'bash', text: securityStopNotRun, isError: true))
        ..add(resultEvent(id: 'x2', actionId: 'a1', toolName: securityAlertTool, text: securityStopResult))
        ..add(stateEvent('s2', ExecutionStatus.paused));
      await pumpEventQueue();
      expect(container.read(codeSessionProvider('s1')).status, SessionStatus.needsInput);
      expect(notifier.shown, hasLength(1));
    });

    test('a stop holds what the app would send on its own until the user writes', () async {
      CodeSessionController.liveAfter = Duration.zero;
      final c = await open(mode: AgentMode.autoEdit);
      await pumpEventQueue();
      session.add(stateEvent('r0', ExecutionStatus.running));
      await pumpEventQueue();
      // Written while the agent worked: queued for the end of its turn.
      await c.send('Also check the tests.');
      expect(container.read(codeSessionProvider('s1')).queued, hasLength(1));
      session
        ..add(actionEvent(id: 'a1', toolName: securityAlertTool, kind: 'ClientToolAction', args: _alert))
        ..add(_waiting('s1'));
      await session.nextAnswer;
      await pumpEventQueue();
      session
        ..add(resultEvent(id: 'x1', actionId: 'a1', toolName: securityAlertTool, text: securityStopResult))
        ..add(stateEvent('s2', ExecutionStatus.paused));
      await pumpEventQueue();
      expect(session.sent, isEmpty);
      expect(session.resumed, 0);
      expect(container.read(codeSessionProvider('s1')).status, SessionStatus.needsInput);
      // The user's reply goes out and ends the hold.
      await c.send('I rotated the key; go on.');
      expect(session.sent.single, contains('I rotated the key; go on.'));
    });

    test('an outside agent\'s host call returns at once; stop_run interrupts its turn', () async {
      final c = await open(harness: 'test');
      HostCall call(Map<String, Object?> args) =>
          HostCall(id: 'h1', sessionId: 's1', name: securityAlertTool, args: args, ended: Completer<HostEnd>().future);
      final go = await c.call(call({..._alert, 'stop_run': false}));
      expect(go, (text: securityShownResult, isError: false));
      expect(session.interrupted, 0);
      final stop = await c.call(call(_alert));
      expect(stop, (text: securityStopResult, isError: false));
      expect(session.interrupted, 1);
      expect(notifier.shown, hasLength(2));
    });
  });
}
