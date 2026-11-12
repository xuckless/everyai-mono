// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/features/code/live/real_input.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
