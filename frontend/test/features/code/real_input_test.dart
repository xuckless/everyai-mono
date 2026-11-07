// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/live/real_input.dart';
import 'package:every_ai/features/code/ui/real_input_consent.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  setUp(() {
    RealInput.consent = RealInputConsent.unasked;
    RealInput.ask = null;
    RealInput.save = null;
  });

  test('asked once, the answer kept; calls meanwhile share the question; no dialog means no', () async {
    expect(await RealInput.ensure(), isFalse);
    expect(RealInput.consent, RealInputConsent.unasked, reason: 'nothing asked, nothing remembered');

    var asked = 0;
    final kept = <bool>[];
    RealInput.ask = () async {
      asked++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return true;
    };
    RealInput.save = kept.add;
    final both = Future.wait([RealInput.ensure(), RealInput.ensure()]);
    expect(RealInput.consent, RealInputConsent.asking);
    expect(await both, [true, true]);
    expect(await RealInput.ensure(), isTrue);
    expect(asked, 1);
    expect(kept, [true]);

    RealInput.set(false);
    expect(await RealInput.ensure(), isFalse);
    expect(asked, 1);
  });

  testWidgets('the dialog asks once and the preference is remembered', (tester) async {
    final prefs = Preferences.inMemory();
    late BuildContext ctx;
    await tester.pumpWidget(
      m.MaterialApp(
        builder: (context, child) =>
            EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: child!),
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      ),
    );
    connectRealInput(prefs, () => ctx);
    final answer = RealInput.ensure();
    await tester.pumpAndSettle();
    expect(find.text('Let agents use your mouse and keyboard?'), findsOneWidget);
    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();
    expect(await answer, isTrue);
    expect(prefs[RealInput.prefKey], '1');

    // A later run starts from the remembered answer, without a dialog.
    RealInput.consent = RealInputConsent.unasked;
    connectRealInput(prefs, () => ctx);
    expect(RealInput.consent, RealInputConsent.allowed);
    expect(await RealInput.ensure(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Let agents use your mouse and keyboard?'), findsNothing);
  });
}
