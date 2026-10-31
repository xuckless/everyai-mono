import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/core/ui/anchored_popover.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  // A phone-sized window: the model chip sits right of center, so the panel is
  // right-aligned and its 320pt width would run off the left edge.
  Future<Rect> openAt(WidgetTester tester, Alignment at, {double? width = 320}) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      m.MaterialApp(
        home: m.Material(
          child: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: Align(
              alignment: at,
              child: AnchoredPopover(
                width: width,
                builder: (context, close) => const SizedBox(key: Key('panel'), height: 200, width: double.infinity),
                child: const SizedBox(width: 150, height: 32, child: Text('trigger')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();
    return tester.getRect(find.byKey(const Key('panel')));
  }

  for (final (name, at) in [
    ('right of center', const Alignment(0.4, -0.2)),
    ('at the right edge', const Alignment(1, -0.2)),
    ('left of center', const Alignment(-0.4, -0.2)),
    ('at the left edge', const Alignment(-1, -0.2)),
  ]) {
    testWidgets('stays inside a phone window with the trigger $name', (tester) async {
      final rect = await openAt(tester, at);
      expect(rect.left, greaterThanOrEqualTo(8 - 1e-6));
      expect(rect.right, lessThanOrEqualTo(393 - 8 + 1e-6));
      expect(rect.width, 320);
    });
  }

  testWidgets('a panel wider than the window shrinks to fit', (tester) async {
    final rect = await openAt(tester, const Alignment(0.4, -0.2), width: 600);
    expect(rect.left, moreOrLessEquals(8));
    expect(rect.right, moreOrLessEquals(393 - 8));
  });

  testWidgets('opens beside a trigger that fades out once the panel is up', (tester) async {
    final hidden = ValueNotifier(false);
    addTearDown(hidden.dispose);
    await tester.pumpWidget(
      m.MaterialApp(
        home: m.Material(
          child: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.cupertino, Brightness.dark),
            child: Padding(
              padding: const EdgeInsets.only(left: 40, top: 300),
              child: Align(
                alignment: Alignment.topLeft,
                child: ValueListenableBuilder(
                  valueListenable: hidden,
                  // A sidebar row's ••• button: shown only while hovered.
                  builder: (context, h, child) => Opacity(opacity: h ? 0 : 1, child: child),
                  child: AnchoredPopover(
                    builder: (context, close) => const SizedBox(key: Key('panel'), height: 100, width: 200),
                    child: const SizedBox(width: 24, height: 24, child: Text('•')),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('•'));
    await tester.pumpAndSettle();
    hidden.value = true;
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(const Key('panel')));
    expect(rect.left, moreOrLessEquals(40));
    // Lower half of the window: it opens upward, its bottom just above the trigger.
    expect(rect.bottom, moreOrLessEquals(300 - 6));
  });
}
