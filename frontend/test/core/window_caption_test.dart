import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/platform/window_caption.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../layout/layout_host.dart';

// Windows and Linux draw their own caption: drag strip plus minimize, maximize and close, which call window_manager.

void main() {
  final calls = <String>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async {
        calls.add(call.method);
        return call.method == 'isMaximized' ? false : null;
      },
    );
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
    testWidgets('caption buttons on ${platform.name}', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      expect(hasCustomCaption, isTrue);
      await tester.pumpWidget(
        const LayoutHost(
          language: DesignLanguage.material,
          child: WindowButtonsOverlay(child: WithWindowCaption(child: SizedBox.expand())),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(WindowCaption)).height, windowCaptionHeight);
      // The drag strip stops where the buttons start, so it never sits under them.
      expect(
        tester.getTopRight(find.byKey(const ValueKey('caption.drag'))).dx,
        tester.getTopLeft(find.byType(WindowButtons)).dx,
      );
      // Windows: flat 46pt cells; Linux: small round buttons.
      final width = tester.getSize(find.byKey(const ValueKey('caption.close'))).width;
      expect(width, platform == TargetPlatform.windows ? 46 : 24);
      for (final b in ['minimize', 'maximize', 'close']) {
        await tester.tap(find.byKey(ValueKey('caption.$b')));
        await tester.pumpAndSettle();
      }
      expect(calls, containsAll(['minimize', 'maximize', 'close']));
      debugDefaultTargetPlatformOverride = null;
    });
  }

  test('macOS keeps its own traffic lights', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(hasCustomCaption, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });
}
