import 'package:every_ai/core/config/billing_flag.dart';
import 'package:every_ai/features/auth/profile.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/settings/domain/byok_providers.dart';
import 'package:every_ai/features/settings/settings_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Credits are parked by default (BILLING_ENABLED unset): no credits, plans
/// or wallet anywhere, and models run on the user's keys.
void main() {
  test('the flag is off by default', () => expect(BillingFlag.enabled, isFalse));

  test('credits are never offered: only keys pay, and a removed key leaves nothing to bill', () {
    const claude = ModelId('anthropic/claude-haiku-5.5');
    const gpt = ModelId('openai/gpt-6.1-sol');
    expect(ModelBilling.empty.billersFor(claude), isEmpty);
    expect(ModelBilling.empty.billerFor(claude).isOwnKey, isFalse);
    expect(ModelBilling.empty.billerFor(claude).label, 'No key yet');
    expect(ModelBilling.empty.headersFor(claude), isEmpty);
    const both = ModelBilling(keys: {'openrouter': 'sk-or-v1-k', 'anthropic': 'sk-ant-k'});
    expect(both.billersFor(claude).map((b) => b.id), ['openrouter', 'anthropic']);
    expect(both.billersFor(gpt).map((b) => b.id), ['openrouter']);
    // A pick of credits from before the switch falls to a key.
    const old = ModelBilling(keys: {'openrouter': 'sk-or-v1-k'}, choices: {'openai/gpt-6.1-sol': 'everyai'});
    expect(old.headersFor(gpt), {'X-Provider-Key-OpenRouter': 'sk-or-v1-k'});
  });

  test('Settings has no Billing: not listed, not searchable, old links land on Account', () {
    expect(SettingsSection.billing.available, isFalse);
    for (final q in ['billing', 'plans', 'wallet', 'top up', 'credits']) {
      expect(searchSettings(q).where((e) => e.section == SettingsSection.billing), isEmpty, reason: q);
    }
    expect(settingsTargetForLocation(Uri.parse('/settings/billing'))?.section, SettingsSection.account);
  });

  test('a profile without a plan parses, and no plan is named', () {
    final p = Profile.fromJson({'id': 'u1', 'name': 'Ada', 'email': 'ada@example.com'})!;
    expect(p.planLabel, isEmpty);
    final withPlan = Profile.fromJson({'id': 'u1', 'name': 'Ada', 'email': 'ada@example.com', 'plan': 'pro'})!;
    expect(withPlan.planLabel, isEmpty);
  });
}
