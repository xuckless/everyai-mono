import 'dart:io';

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/acp/acp_driver.dart';
import 'package:every_ai/features/code/drivers/claude/claude_driver.dart';
import 'package:every_ai/features/code/drivers/codex/codex_driver.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_policy.dart';
import 'package:every_ai/features/code/drivers/driver_process.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/drivers/everyai_driver.dart';
import 'package:every_ai/features/code/drivers/opencode/opencode_driver.dart';
import 'package:every_ai/features/code/drivers/terminal/terminal_driver.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/harness/session_processes.dart' show driverRootsOf;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A session that records what the policy asks of it.
final class _Session implements HarnessSession, SteersRuns {
  final calls = <String>[];

  @override
  String get id => 's';
  @override
  Stream<HarnessEvent> get events => const Stream.empty();
  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async => calls.add('send $text');
  @override
  Future<void> interrupt() async => calls.add('interrupt');
  @override
  Future<void> steer(String text, {List<String> images = const []}) async => calls.add('steer $text');
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async {}
  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) async {}
  @override
  Future<void> switchLlm(SessionSpec spec) async {}
  @override
  Future<void> rewindTo(String? head) async {}
  @override
  Future<void> close() async {}
}

void main() {
  group('registry', () {
    late ProviderContainer container;
    setUp(
      () => container = ProviderContainer(
        overrides: [
          harnessProvider.overrideWithValue(FakeHarness()),
          preferencesProvider.overrideWithValue(Preferences.inMemory()),
        ],
      ),
    );
    tearDown(() => container.dispose());

    test('every planned driver is registered under its stored name', () {
      final r = container.read(driverRegistryProvider);
      expect(r.resolve('everyai'), isA<EveryAIDriver>());
      expect(r.resolve('claude-code'), isA<ClaudeDriver>());
      expect(r.resolve('codex'), isA<CodexDriver>());
      expect(r.resolve('opencode'), isA<OpenCodeDriver>());
      final gemini = r.resolve('gemini')! as AcpDriver;
      expect((gemini.info.needsConsent, gemini.command), (true, 'gemini'));
      expect(gemini.info.label, 'Gemini CLI (API key or enterprise)');
      expect(gemini.resolved.args, ['--acp']);
      expect(r.resolve('claude-code')!.info.needsConsent, isTrue);
      expect(r.resolve('codex')!.info.needsConsent, isFalse);
      final acp = r.resolve('acp:goose')!;
      expect(acp, isA<AcpDriver>());
      expect((acp.info.id, (acp as AcpDriver).command), ('acp:goose', 'goose'));
      expect(acp.resolved.args, ['acp']);
      expect(identical(r.resolve('acp:goose'), acp), isTrue);
      expect(r.resolve('terminal:aider'), isA<TerminalDriver>());
      expect(r.resolve('terminal:aider')!.info.id, 'terminal:aider');
      expect(r.resolve('acp:'), isNull);
      expect(r.resolve('nope'), isNull);
      expect(
        [for (final d in r.listed) d.info.id],
        [
          'everyai',
          'claude-code',
          'codex',
          'opencode',
          'antigravity',
          'gemini',
          'github-copilot-cli',
          'kiro',
          'kimi',
          'qwen-code',
          'cline',
          'goose',
          'mistral-vibe',
          'auggie',
          'factory-droid',
          'cursor',
          'grok',
        ],
      );
    });
  });

  group('the EveryAI driver', () {});

  group('fallbacks', () {
    test('steer runs in place when the driver can, else interrupts and sends again', () async {
      final s = _Session();
      Future<void> steer(SteersRuns r) => r.steer('hi');
      Future<void> resend() => s.send('hi');
      await steerOrResend(s, {DriverCap.steer}, steer: steer, resend: resend);
      expect(s.calls, ['steer hi']);
      s.calls.clear();
      await steerOrResend(s, const {}, steer: steer, resend: resend);
      expect(s.calls, ['interrupt', 'send hi']);
    });

    test('only kinds the rules understand are decided without the user', () {
      ActionCall call(String kind, [String tool = 'Bash', Map<String, Object?> args = const {}]) =>
          actionEvent(id: 'a', toolName: tool, kind: kind, args: args);
      expect(autoDecidable(call('TerminalAction', 'Bash', {'command': 'ls'})), isTrue);
      expect(autoDecidable(call('FileEditorAction', 'Edit', {'command': 'str_replace', 'path': 'a.dart'})), isTrue);
      expect(autoDecidable(call('MCPToolAction', 'github_search')), isTrue);
      expect(autoDecidable(call('ClaudeTaskAction', 'Task')), isFalse);
      expect(autoDecidable(call('BrowserAction', 'browser')), isFalse);
    });

    test('a known kind without the fields its rules read asks the user', () {
      ActionCall call(String kind, Map<String, Object?> args) =>
          actionEvent(id: 'a', toolName: 'native', kind: kind, args: args);
      // A patch to an outside or denied path would pass on an empty list.
      expect(autoDecidable(call('ApplyPatchAction', {'patch': '*** Begin Patch'})), isFalse);
      expect(autoDecidable(call('ApplyPatchAction', {'patch': '*** Begin Patch', 'paths': <String>[]})), isFalse);
      expect(
        autoDecidable(
          call('ApplyPatchAction', {
            'paths': ['../../.ssh/authorized_keys'],
          }),
        ),
        isTrue,
      );
      // Claude Code's native key instead of ours.
      expect(autoDecidable(call('WriteFileAction', {'file_path': '/etc/hosts'})), isFalse);
      expect(autoDecidable(call('FileEditorAction', {'command': 'create', 'file_path': 'a'})), isFalse);
      expect(autoDecidable(call('EditAction', {'path': ''})), isFalse);
      expect(autoDecidable(call('ReadFileAction', {})), isFalse);
      expect(autoDecidable(call('TerminalAction', {'cmd': 'rm -rf /'})), isFalse);
    });
  });

  test('a line sent after the CLI died is dropped, not an uncaught pipe error', () async {
    final dir = Directory.systemTemp.createTempSync('driver_proc');
    addTearDown(() => dir.deleteSync(recursive: true));
    final p = await spawnDriver(
      executable: '/bin/sh',
      args: ['-c', 'exit 3'],
      cwd: dir.path,
      sessionTag: 'dead-cli',
      logPath: '${dir.path}/log/driver.log',
    );
    expect(await p.exitCode, 3);
    expect(driverRootsOf('dead-cli'), isEmpty);
    p.send('{"jsonrpc":"2.0","id":1,"result":{}}');
    await pumpEventQueue();
    await p.close();
  });

  group('outside leads', () {
    test('a lead is blocked for the first reason in order', () {
      const plain = DriverInfo(id: 'codex', label: 'Codex');
      const paid = DriverInfo(id: 'claude-code', label: 'Claude Code', needsConsent: true);
      String? b(DriverInfo i, DriverStatus? s, {bool consented = false}) => leadBlocked(i, s, consented: consented);
      expect(b(const DriverInfo(id: 'everyai', label: 'EveryAI'), null), isNull);
      expect(b(plain, null), 'Checking…');
      expect(b(plain, const DriverStatus(installed: true, problem: notBuiltProblem)), 'Not built yet');
      expect(b(plain, const DriverStatus()), 'Not installed');
      expect(b(plain, const DriverStatus(installed: true, signedIn: false)), 'Not signed in');
      expect(b(paid, const DriverStatus(installed: true, signedIn: true)), 'Turn on in Settings');
      expect(b(paid, const DriverStatus(installed: true), consented: true), isNull);
      expect(b(plain, const DriverStatus(installed: true, problem: 'Too old')), 'Too old');
    });
  });
}
