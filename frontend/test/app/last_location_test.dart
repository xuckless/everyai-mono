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

  test('chats, Code home, sessions, the Board and top-level pages come back at launch', () {
    for (final at in ['/chat/abc', '/code', '/code/board', '/code/s/s1', '/chats', '/artifacts', '/models']) {
      expect(restorableLocation(at), isTrue, reason: at);
    }
    for (final at in ['/sign-in', '/settings/billing', '/code/settings', '/']) {
      expect(restorableLocation(at), isFalse, reason: at);
    }
  });

  test('the saved screen is reopened; a removed Code session falls back to Code home', () {
    expect(restore({}), isNull);
    expect(restore({lastLocationKey: '/chat/abc'}), '/chat/abc');
    expect(restore({lastLocationKey: '/code/board'}), '/code/board');
    expect(restore({lastLocationKey: '/settings/billing'}), isNull);
    expect(restore({lastLocationKey: '/code/s/gone'}), '/code');
  });
}
