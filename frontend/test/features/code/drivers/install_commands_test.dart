import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/code_providers.dart' show harnessProvider;
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:every_ai/features/code/drivers/detection/install_commands.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _vendorHosts = {
  'code.claude.com',
  'github.com',
  'opencode.ai',
  'cursor.com',
  'antigravity.google',
  'kiro.dev',
  'docs.augmentcode.com',
  'docs.factory.ai',
  'x.ai',
  'ollama.com',
};

void main() {
  final rows = [
    for (final id in setupDriverIds)
      for (final os in SetupOs.values)
        if (setupCommandsFor(id, os) case final c?) (id, os, c),
  ];

  test('every row names an https vendor page it comes from', () {
    expect(rows, isNotEmpty);
    for (final (id, os, c) in rows) {
      final uri = Uri.parse(c.source);
      expect(uri.scheme, 'https', reason: '$id $os');
      expect(_vendorHosts, contains(uri.host), reason: '$id $os');
    }
  });

  test('the install lines are one line and fetch from https only', () {
    for (final (id, os, c) in rows) {
      expect(c.install, isNot(anyOf(contains('\n'), contains(';'))), reason: '$id $os');
      expect(c.install, isNot(contains('http://')), reason: '$id $os');
    }
  });

  test('Claude Code, Codex, OpenCode and Cursor have a line for every system, read from the vendor', () {
    for (final id in ['claude-code', 'codex', 'opencode', 'cursor']) {
      for (final os in SetupOs.values) {
        expect(setupCommandsFor(id, os)?.verified, isTrue, reason: '$id $os');
      }
    }
  });

  test('a Windows line runs in PowerShell, since our Windows terminal is cmd.exe', () {
    for (final id in ['claude-code', 'codex', 'cursor']) {
      expect(setupCommandsFor(id, SetupOs.windows)!.install, startsWith('powershell -NoProfile'), reason: id);
    }
    expect(setupCommandsFor('opencode', SetupOs.windows)!.install, 'npm install -g opencode-ai');
  });

  test('the sign-in arguments are the ones the CLIs print in --help', () {
    expect(setupCommandsFor('claude-code', SetupOs.macos)!.login, ['auth', 'login']);
    expect(setupCommandsFor('codex', SetupOs.linux)!.login, ['login']);
    expect(setupCommandsFor('opencode', SetupOs.windows)!.login, ['auth', 'login']);
  });

  test('every listed ACP agent with an install hint has a Unix row, and the own harness has none', () {
    final c = ProviderContainer(
      overrides: [
        harnessProvider.overrideWithValue(FakeHarness()),
        preferencesProvider.overrideWithValue(Preferences.inMemory()),
      ],
    );
    addTearDown(c.dispose);
    final registry = c.read(driverRegistryProvider);
    for (final d in registry.listed) {
      if (d.info.id == 'everyai') {
        expect(setupCommandsFor('everyai', SetupOs.macos), isNull);
      } else if (d.info.installHint != null) {
        expect(setupCommandsFor(d.info.id, SetupOs.macos), isNotNull, reason: d.info.id);
        expect(setupCommandsFor(d.info.id, SetupOs.linux), isNotNull, reason: d.info.id);
      }
    }
  });

  test('phones and the web have no system', () {
    expect(SetupOs.of(TargetPlatform.android), isNull);
    expect(SetupOs.of(TargetPlatform.iOS), isNull);
    expect(SetupOs.of(TargetPlatform.windows), SetupOs.windows);
  });
}
