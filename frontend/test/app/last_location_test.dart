import 'package:every_ai/app/router.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final restored = Provider<String?>(restoredLocation);

  String? restore(Map<String, String> prefs) {
    final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(Preferences.inMemory(prefs))]);
    addTearDown(c.dispose);
    return c.read(restored);
  }

  test('the saved screen is reopened; a removed Code session falls back to Code home', () {
    expect(restore({}), isNull);
    expect(restore({lastLocationKey: '/chat/abc'}), '/chat/abc');
    expect(restore({lastLocationKey: '/code/board'}), '/code/board');
    expect(restore({lastLocationKey: '/settings/billing'}), isNull);
    expect(restore({lastLocationKey: '/code/s/gone'}), '/code');
  });
}
