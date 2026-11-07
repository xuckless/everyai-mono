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
Widget _composer({
  required List<String> queued,
  required ValueChanged<int> onSendNow,
  required ValueChanged<int> onRemove,
}) => ProviderScope(
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
            queued: queued,
            onUnqueue: onRemove,
            onSendQueuedNow: onSendNow,
          ),
        ),
      ),
    ),
  ),
);

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

  testWidgets('a double click on Send now sends one message, not the one that moves into its place', (tester) async {
    var queued = ['first', 'second'];
    final sentNow = <String>[];
    late StateSetter rebuild;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return _composer(
            queued: queued,
            onSendNow: (i) => rebuild(() {
              sentNow.add(queued[i]);
              queued = [...queued]..removeAt(i);
            }),
            onRemove: (_) {},
          );
        },
      ),
    );
    await tester.pump();
    Finder sendNow() => find.descendant(
      of: find.byKey(const ValueKey('composer.queued.0')),
      matching: find.byKey(const ValueKey('composer.queued.send-now')),
    );
    await tester.tap(sendNow());
    await tester.pump();
    // The second message is now the first chip, under the pointer.
    await tester.tap(sendNow());
    await tester.pump();
    expect(sentNow, ['first']);
  });
}
