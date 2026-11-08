// The macOS menu bar is mounted once, at the app root, and nothing else builds one: a second PlatformMenuBar that
// mounts before the first is disposed asserts in platform_menu_bar.dart (the crash this guards against).

import 'dart:io';

import 'package:every_ai/app/app_menu.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

ShellMenuActions _actions(List<String> log) => ShellMenuActions(
  openSettings: () => log.add('settings'),
  newChat: () => log.add('new chat'),
  toggleSidebar: () => log.add('sidebar'),
  openModels: () => log.add('models'),
);

PlatformMenuItem _item(List<PlatformMenuItem> menus, String label) {
  for (final m in menus) {
    final found = switch (m) {
      PlatformMenu(:final menus) => _items(menus).where((i) => i.label == label).firstOrNull,
      _ => null,
    };
    if (found != null) return found;
  }
  throw StateError('no item $label');
}

Iterable<PlatformMenuItem> _items(List<PlatformMenuItem> menus) sync* {
  for (final m in menus) {
    if (m is PlatformMenuItemGroup) {
      yield* _items(m.members);
    } else {
      yield m;
    }
  }
}

/// [body] on [platform]; the override is reset inside the test (Flutter checks it before tear-downs run).
Future<void> Function(WidgetTester) _on(TargetPlatform platform, Future<void> Function(WidgetTester) body) =>
    (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    };

/// Lets the holder's microtask notify, then rebuilds.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  tearDown(AppMenuActions.instance.reset);

  test('only the app root builds a PlatformMenuBar', () {
    final builders = [
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') && f.readAsStringSync().contains('PlatformMenuBar(')) f.path,
    ];
    expect(builders, [endsWith('app/app_menu.dart')], reason: 'mount the menu bar once (see app_menu.dart)');
    expect(File('lib/app/app.dart').readAsStringSync(), contains('return AppMenuBar('));
  });

  testWidgets(
    'the bar stays one element while everything under it is rebuilt, wrapped and swapped',
    _on(TargetPlatform.macOS, (tester) async {
      Widget page(int i) => Directionality(
        textDirection: TextDirection.ltr,
        child: switch (i % 3) {
          0 => const SizedBox(key: ValueKey('a')),
          // The banner's Stack, the onboarding gate: the page moves under a new parent.
          1 => const Stack(
            children: [
              SizedBox(key: ValueKey('a')),
              Text('Waking up…', textDirection: TextDirection.ltr),
            ],
          ),
          _ => const Center(child: Text('Onboarding', textDirection: TextDirection.ltr)),
        },
      );
      await tester.pumpWidget(AppMenuBar(child: page(0)));
      final first = tester.element(find.byType(PlatformMenuBar));
      for (var i = 1; i < 10; i++) {
        await tester.pumpWidget(AppMenuBar(child: page(i)));
        expect(tester.takeException(), isNull);
        expect(find.byType(PlatformMenuBar), findsOneWidget);
        expect(tester.element(find.byType(PlatformMenuBar)), same(first));
      }
    }),
  );

  testWidgets(
    "the shell's actions: greyed out until lent, gone with their owner, a newer owner wins",
    _on(TargetPlatform.macOS, (tester) async {
      await tester.pumpWidget(const AppMenuBar(child: SizedBox()));
      List<PlatformMenuItem> menus() => tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar)).menus;
      expect(_item(menus(), 'Settings…').onSelected, isNull);

      final log = <String>[];
      final old = Object(), shell = Object();
      AppMenuActions.instance.lend(old, _actions(['old']));
      AppMenuActions.instance.lend(shell, _actions(log));
      // An old shell going away after the new one lent its actions takes nothing with it.
      AppMenuActions.instance.release(old);
      await _settle(tester);
      _item(menus(), 'Settings…').onSelected!();
      _item(menus(), 'New Chat').onSelected!();
      _item(menus(), 'Toggle Sidebar').onSelected!();
      _item(menus(), 'Models').onSelected!();
      expect(log, ['settings', 'new chat', 'sidebar', 'models']);

      AppMenuActions.instance.release(shell);
      await _settle(tester);
      expect(_item(menus(), 'New Chat').onSelected, isNull);
    }),
  );

  testWidgets(
    'a lend or release inside a build waits for a microtask (the tree is locked then)',
    _on(TargetPlatform.macOS, (tester) async {
      final owner = Object();
      await tester.pumpWidget(
        AppMenuBar(
          child: Builder(
            builder: (context) {
              AppMenuActions.instance.lend(owner, _actions([]));
              return const SizedBox();
            },
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await _settle(tester);
      expect(_item(tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar)).menus, 'Models').onSelected, isNotNull);
    }),
  );

  testWidgets(
    'other hosts get no bar, only the app',
    _on(TargetPlatform.windows, (tester) async {
      await tester.pumpWidget(const AppMenuBar(child: SizedBox(key: ValueKey('app'))));
      expect(find.byType(PlatformMenuBar), findsNothing);
      expect(find.byKey(const ValueKey('app')), findsOneWidget);
    }),
  );
}
