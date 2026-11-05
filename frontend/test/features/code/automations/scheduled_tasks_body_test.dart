import 'dart:convert';

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/core/ui/adaptive.dart';
import 'package:every_ai/features/code/automations/schedule_providers.dart';
import 'package:every_ai/features/code/automations/ui/scheduled_tasks_body.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  testWidgets('a bad cron shows why and Save stays off; a good one lists the next runs', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = Preferences.inMemory({
      'code.projects': jsonEncode([
        {'id': 'p', 'name': 'app', 'path': '/work/app'},
      ]),
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          scheduleTickProvider.overrideWithValue(null),
          scheduleClockProvider.overrideWithValue(() => DateTime(2026, 11, 5, 8)),
        ],
        child: m.MaterialApp(
          home: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: const m.Material(child: ScheduledTasksBody()),
          ),
        ),
      ),
    );
    expect(find.text('No scheduled tasks yet'), findsOneWidget);
    await tester.tap(find.text('Add task'));
    await tester.pumpAndSettle();

    bool saveOn() => tester.widget<AdaptiveButton>(find.widgetWithText(AdaptiveButton, 'Save')).onPressed != null;
    final fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), 'Morning triage');
    await tester.enterText(fields.at(2), 'Look at overnight failures');
    await tester.pump();
    expect(saveOn(), isTrue);
    expect(find.textContaining('Next: Nov 5 09:00, Nov 6 09:00'), findsOneWidget);

    await tester.tap(find.text('Every day'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cron expression').last);
    await tester.pumpAndSettle();
    await tester.enterText(fields.at(3), '61 * * * *');
    await tester.pump();
    expect(find.textContaining('not a valid minute'), findsOneWidget);
    expect(saveOn(), isFalse);

    await tester.enterText(fields.at(3), '0 9 * * 1-5');
    await tester.pump();
    expect(saveOn(), isTrue);
    await tester.tap(find.widgetWithText(AdaptiveButton, 'Save'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(ScheduledTasksBody)));
    final saved = container.read(scheduledTasksProvider).single;
    expect(saved.name, 'Morning triage');
    expect(saved.schedule.cron, '0 9 * * 1-5');
    expect(find.text('Morning triage'), findsOneWidget);
  });
}
