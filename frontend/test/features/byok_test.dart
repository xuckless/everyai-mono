import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/billing/billing_providers.dart';
import 'package:every_ai/features/billing/ui/billing_screen.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/settings/byok_keys.dart';
import 'package:every_ai/features/settings/domain/byok_providers.dart';
import 'package:every_ai/features/settings/ui/api_keys_section.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

final class _MemoryStore implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Billing extends BillingController {
  @override
  Future<BillingSummary> build() async => BillingSummary.fromJson({
    'plan': {'id': 'free', 'name': 'Free', 'price_cents': 0, 'included_micros': 0},
    'period_end': 1795000000,
    'included_micros': 0,
    'used_micros': 0,
    'wallet_micros': 0,
  });
}

Widget _app(List<Override> overrides, Widget child) => ProviderScope(
  overrides: [preferencesProvider.overrideWithValue(Preferences.inMemory()), ...overrides],
  child: m.MaterialApp(
    builder: (context, c) =>
        EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: c!),
    home: m.Material(child: child),
  ),
);

void main() {
  test('the provider list is complete and ids are unique', () {
    expect(byokProviders, hasLength(12));
    expect(byokProviders.map((p) => p.id).toSet(), hasLength(12));
    expect(byokProviders.map((p) => p.name), containsAll(['Anthropic', 'OpenRouter', 'Moonshot (Kimi)']));
  });

  test('keys go to the keychain under byok.<id>; the state keeps only the last four', () async {
    final store = _MemoryStore()..values['byok.openai'] = 'sk-abcdefgh1234';
    final c = ProviderContainer(overrides: [secretStoreProvider.overrideWithValue(store)]);
    addTearDown(c.dispose);
    expect(await c.read(byokKeysProvider.future), {'openai': '1234'});
    await c.read(byokKeysProvider.notifier).save('anthropic', '  sk-ant-xyz9876 ');
    expect(store.values['byok.anthropic'], 'sk-ant-xyz9876');
    expect(c.read(byokKeysProvider).value, {'openai': '1234', 'anthropic': '9876'});
    await c.read(byokKeysProvider.notifier).remove('openai');
    expect(store.values.containsKey('byok.openai'), isFalse);
    expect(c.read(byokKeysProvider).value, {'anthropic': '9876'});
    await c.read(byokKeysProvider.notifier).save('anthropic', '');
    expect(store.values, isEmpty);
  });

  testWidgets('a card adds a key behind a masked field and removes it', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _MemoryStore();
    await tester.pumpWidget(_app([secretStoreProvider.overrideWithValue(store)], const ApiKeysSection()));
    await tester.pumpAndSettle();
    expect(find.text('Bring your own key — coming soon'), findsOneWidget);
    expect(find.text('Not connected'), findsNWidgets(12));

    await tester.tap(find.byKey(const ValueKey('byok.groq.add')));
    await tester.pumpAndSettle();
    final field = find.descendant(of: find.byType(m.AlertDialog), matching: find.byType(EditableText));
    expect(tester.widget<EditableText>(field).obscureText, isTrue);
    await tester.enterText(field, 'gsk_secret_ABCD');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(store.values['byok.groq'], 'gsk_secret_ABCD');
    expect(find.text('•••• ABCD'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('byok.groq.more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove key'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(store.values, isEmpty);
    expect(find.text('Not connected'), findsNWidgets(12));
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('Billing shows the static plans; Choose says it is coming', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app([billingProvider.overrideWith(_Billing.new)], const BillingBody()));
    await tester.pumpAndSettle();
    expect(find.text('Requires an account.'), findsOneWidget);
    expect(find.text('~\$20/mo'), findsOneWidget);
    expect(find.text('~\$100/mo'), findsOneWidget);
    expect(find.text('Pay as you go'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plans.choose.super')));
    await tester.pump();
    expect(find.text('Super is coming soon.'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });
}
