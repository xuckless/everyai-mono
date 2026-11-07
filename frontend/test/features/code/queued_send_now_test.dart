// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/ui/code_composer.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

// A queued message can go now (interrupting the agent) instead of waiting for the turn to end.
void main() {
  testWidgets('each queued message has Send now and Remove', (tester) async {
    final sentNow = <int>[];
    final removed = <int>[];
    await tester.pumpWidget(
      ProviderScope(
        child: m.MaterialApp(
          home: m.Material(
            child: EveryThemeScope(
              theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: CodeComposer(
                  busy: true,
                  mode: AgentMode.ask,
                  onModeChanged: (_) {},
                  onSend: (_, _) {},
                  onStop: () {},
                  queued: const ['first', 'second'],
                  onUnqueue: removed.add,
                  onSendQueuedNow: sentNow.add,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final second = find.byKey(const ValueKey('composer.queued.1'));
    expect(second, findsOneWidget);
    await tester.tap(find.descendant(of: second, matching: find.byKey(const ValueKey('composer.queued.send-now'))));
    expect(sentNow, [1]);
    expect(removed, isEmpty);
  });
}
