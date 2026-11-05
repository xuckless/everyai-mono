import 'dart:convert';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/agent_models.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/environments/bridges.dart';
import 'package:every_ai/features/code/environments/discovery.dart' show sshRemotesKey;
import 'package:every_ai/features/code/environments/environment_label.dart';
import 'package:every_ai/features/code/environments/environment_picker.dart';
import 'package:every_ai/features/code/environments/environment_providers.dart';
import 'package:every_ai/features/code/environments/environment_statuses.dart';
import 'package:every_ai/features/code/environments/exec_env.dart';
import 'package:every_ai/features/code/environments/ssh_remote_form.dart';
import 'package:every_ai/features/code/settings/agent_prompt.dart' show HarnessTier;
import 'package:every_ai/features/code/ui/agent_menu.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../../../support/fake_leads.dart';
import 'env_fakes.dart';

// The environment UI: the label helper, the project's setter, the picker and chip, the ssh form, and the lead
// picker per environment.

Widget _app(Widget child, {List<Override> overrides = const []}) => ProviderScope(
  overrides: overrides,
  child: m.MaterialApp(
    builder: (context, child) =>
        EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: child!),
    home: m.Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 600, child: child),
      ),
    ),
  ),
);

final _ubuntu = FakeEnv();
final _debian = FakeEnv(id: 'wsl:Debian', label: 'Debian (WSL)');

void main() {
  group('labels and the ssh target', () {
    test('only an environment other than this computer is named', () {
      expect(harnessLabel('Claude Code', HostEnv.instance), 'Claude Code');
      expect(harnessLabel('Claude Code', null), 'Claude Code');
      expect(harnessLabel('Claude Code', _ubuntu), 'Claude Code · Ubuntu (WSL)');
      expect(harnessLabel('Codex', FakeEnv(id: 'ssh:box', kind: EnvKind.ssh, label: 'box (SSH)')), 'Codex · box (SSH)');
    });

    test('an alias or user@host passes; spaces, a leading dash and shell characters do not', () {
      for (final ok in ['devbox', 'me@devbox', ' me@dev-box.example.com ', 'a_b.c']) {
        expect(validSshTarget(ok), isTrue, reason: ok);
      }
      for (final bad in [
        '',
        '  ',
        'my box',
        '-oProxyCommand=x',
        'me@-host',
        'a;b',
        'a\nb',
        r'$(id)',
        'a|b',
        'a@b@c',
        'a:22',
      ]) {
        expect(validSshTarget(bad), isFalse, reason: bad);
      }
    });

    test('parsing gives an alias or a user and host, with the optional label', () {
      final alias = parseSshTarget('devbox', label: ' Build box ')!;
      expect((alias.alias, alias.name), ('devbox', 'Build box'));
      final host = parseSshTarget('me@devbox')!;
      expect((host.user, host.host, host.name), ('me', 'devbox', null));
      expect(parseSshTarget('me devbox'), isNull);
    });

    test('a label shows instead of the host and survives JSON', () {
      const r = SshRemote.alias('devbox', name: 'Build box');
      expect(SshEnv(cli: '/usr/bin/ssh', remote: r).label, 'Build box (SSH)');
      expect(SshRemote.fromJson(jsonDecode(jsonEncode(r.toJson())))!.name, 'Build box');
      expect(const SshRemote.alias('devbox').toJson(), {'alias': 'devbox'});
    });
  });

  test('setEnvironment stores the choice, keeps the rest, and host leaves no key', () {
    final prefs = Preferences.inMemory({
      'code.projects': jsonEncode([
        {'id': 'p1', 'name': 'app', 'path': '/work/app'},
        {'id': 'p2', 'name': 'other', 'path': '/work/other'},
      ]),
    });
    final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    c.read(codeProjectsProvider.notifier).setEnvironment('p1', 'wsl:Ubuntu');
    expect([for (final p in c.read(codeProjectsProvider)) p.environment], ['wsl:Ubuntu', 'host']);
    final stored = jsonDecode(prefs['code.projects']!) as List;
    expect((stored.first as Map)['environment'], 'wsl:Ubuntu');
    expect((stored.last as Map).containsKey('environment'), isFalse);
    c.read(codeProjectsProvider.notifier).setEnvironment('p1', 'host');
    expect((jsonDecode(prefs['code.projects']!) as List).first, isNot(contains('environment')));
  });

  group('the picker', () {
    List<Override> envs([List<ExecEnv>? list]) => [
      environmentsProvider.overrideWith((ref) async => list ?? [HostEnv.instance, _ubuntu, _debian]),
    ];

    testWidgets('lists every environment, also one with no CLIs, and picks one', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(
        _app(
          EnvironmentMenu(envId: 'host', onPick: picked.add, child: const Text('open')),
          overrides: envs(),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      for (final id in ['host', 'wsl:Ubuntu', 'wsl:Debian']) {
        expect(find.byKey(ValueKey('environment.$id')), findsOneWidget, reason: id);
      }
      expect(find.byKey(const ValueKey('environment.add-ssh')), findsOneWidget);
      expect(find.byKey(const ValueKey('environment.rescan')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('environment.wsl:Ubuntu')));
      await tester.pumpAndSettle();
      expect(picked, ['wsl:Ubuntu']);
      expect(find.byKey(const ValueKey('environment.rescan')), findsNothing);
    });

    testWidgets('an environment that is gone stays listed as picked', (tester) async {
      await tester.pumpWidget(
        _app(
          EnvironmentMenu(envId: 'wsl:Old', onPick: (_) {}, child: const Text('open')),
          overrides: envs(),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('environment.wsl:Old')), findsOneWidget);
      expect(find.textContaining('Not found'), findsOneWidget);
    });

    testWidgets('the chip names where it runs and changes it', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(
        _app(
          EnvironmentChip(envId: 'wsl:Ubuntu', onPick: picked.add),
          overrides: envs(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Runs in'), findsOneWidget);
      expect(find.text('Ubuntu (WSL)'), findsOneWidget);
      await tester.tap(find.text('Ubuntu (WSL)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('environment.host')));
      await tester.pumpAndSettle();
      expect(picked, ['host']);
    });

    testWidgets('Add SSH remote opens the form; saving adds the remote', (tester) async {
      final prefs = Preferences.inMemory();
      await tester.pumpWidget(
        _app(
          EnvironmentMenu(envId: 'host', onPick: (_) {}, child: const Text('open')),
          overrides: [...envs(), preferencesProvider.overrideWithValue(prefs)],
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('environment.add-ssh')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('ssh-form.target')), 'me@devbox');
      await tester.enterText(find.byKey(const ValueKey('ssh-form.label')), 'Build box');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ssh-form.save')));
      await tester.pumpAndSettle();
      final c = ProviderScope.containerOf(tester.element(find.text('open')));
      final remote = c.read(sshRemotesProvider).single;
      expect((remote.destination, remote.name), ('me@devbox', 'Build box'));
      expect(prefs[sshRemotesKey], isNotNull);
      // Back on the list.
      expect(find.byKey(const ValueKey('environment.rescan')), findsOneWidget);
    });
  });

  group('the ssh form', () {
    testWidgets('a target is required; the label is optional; keys only is said', (tester) async {
      final saved = <SshRemote>[];
      await tester.pumpWidget(_app(SshRemoteForm(onSave: saved.add, onCancel: () {})));
      expect(find.textContaining('never asks for or stores a password'), findsOneWidget);
      m.FilledButton save() => tester.widget(
        find.descendant(of: find.byKey(const ValueKey('ssh-form.save')), matching: find.byType(m.FilledButton)),
      );
      expect(save().onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('ssh-form.target')), 'bad host');
      await tester.pump();
      expect(save().onPressed, isNull);
      expect(find.textContaining('No spaces'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('ssh-form.target')), 'devbox');
      await tester.pump();
      expect(save().onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('ssh-form.save')));
      expect(saved.single.alias, 'devbox');
      expect(saved.single.name, isNull);
    });
  });

  group('the lead picker per environment', () {
    Future<void> openLeads(WidgetTester tester, String environment, {bool harnessPage = true}) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          AgentMenu(
            harness: 'everyai',
            onHarness: (_) {},
            model: 'anthropic/claude-opus-5.5',
            effort: 'medium',
            onChanged: (_, _) {},
            level: HarnessTier.efficient,
            onLevel: (_) {},
            environment: environment,
          ),
          overrides: [
            preferencesProvider.overrideWithValue(Preferences.inMemory()),
            modelCatalogProvider.overrideWith(FixedCatalog.new),
            agentCatalogProvider.overrideWithBuild((ref, _) => AgentCatalog.builtIn),
            environmentsProvider.overrideWith((ref) async => [HostEnv.instance, _ubuntu, _debian]),
            driverRegistryProvider.overrideWithValue(
              DriverRegistry({
                'everyai': FakeLeadDriver('everyai', label: 'EveryAI'),
                'alpha': FakeLeadDriver('alpha', label: 'Alpha CLI'),
              }),
            ),
            // Alpha (a fake that reads as installed) is on the host and in Ubuntu only.
            driverStatusesProvider.overrideWith(() => DriverStatuses(loadShell: () async {}, reloadShell: () async {})),
            driverStatusesInProvider('wsl:Ubuntu')
                .overrideWith((ref) async => {'alpha': const DriverStatus(installed: true, version: '1.0')}),
            driverStatusesInProvider('wsl:Debian').overrideWith((ref) async => const {}),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(AgentMenuPart).first);
      await tester.pumpAndSettle();
      if (!harnessPage) return;
      await tester.tap(find.text('Harness'));
      await tester.pumpAndSettle();
    }

    testWidgets('a harness found only in the distro is offered there, named with it', (tester) async {
      await openLeads(tester, 'wsl:Ubuntu');
      expect(find.byKey(const ValueKey('agent-menu.harness.alpha')), findsOneWidget);
      expect(find.text('Alpha CLI · Ubuntu (WSL)'), findsOneWidget);
      expect(find.text('EveryAI · Ubuntu (WSL)'), findsOneWidget);
    });

    testWidgets('one not installed in the distro is left out', (tester) async {
      // Only EveryAI could lead there, so the menu has no Harness row to open.
      await openLeads(tester, 'wsl:Debian', harnessPage: false);
      expect(find.text('Harness'), findsNothing);
      expect(find.text('Alpha CLI'), findsNothing);
    });

    testWidgets('on this computer names carry no environment', (tester) async {
      await openLeads(tester, 'host');
      expect(find.text('Alpha CLI'), findsOneWidget);
      expect(find.textContaining('(WSL)'), findsNothing);
    });
  });
}
