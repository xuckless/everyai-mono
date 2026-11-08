import 'dart:async';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/live/live_browsers.dart';
import 'package:every_ai/features/code/live/login_wall.dart';
import 'package:every_ai/features/code/ui/panes/browser_sign_ins.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  testWidgets('the card shows while the agent waits at a sign-in page; Skip lets it go on', (tester) async {
    final b = LiveBrowsers.forSession('wall-card', profileDir: '/tmp/none');
    addTearDown(() => LiveBrowsers.release('wall-card'));
    await tester.pumpWidget(
      ProviderScope(
        child: m.MaterialApp(
          builder: (context, c) =>
              EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: c!),
          home: const m.Material(child: LoginWallCard(sessionId: 'wall-card')),
        ),
      ),
    );
    expect(find.textContaining('Sign in to'), findsNothing);
    WallOutcome? outcome;
    unawaited(
      b.loginWall
          .hold(
            'github.com',
            'https://github.com/login',
            probe: () async => (url: 'https://github.com/login', password: true),
            every: const Duration(milliseconds: 100),
          )
          .then((o) => outcome = o),
    );
    await tester.pump();
    expect(find.textContaining('Sign in to github.com'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('login-wall.skip.wall-card')));
    await tester.pump();
    expect(outcome, WallOutcome.skipped);
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Sign in to'), findsNothing);
  });
}
