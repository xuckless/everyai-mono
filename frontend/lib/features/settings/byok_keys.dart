import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/preferences.dart';
import '../code/gateway_key.dart' show SecretStore, secretStoreProvider;
import '../models/domain/model_catalog.dart';
import 'domain/byok_providers.dart';

/// The user's own provider keys, kept in the system keychain (secure storage
/// elsewhere) under `byok.<provider id>`, never on our servers. The state is
/// provider id → the whole key; screens show only its last four characters.
final byokKeysProvider = AsyncNotifierProvider<ByokKeys, Map<String, String>>(ByokKeys.new);

final class ByokKeys extends AsyncNotifier<Map<String, String>> {
  static String storeKey(String providerId) => 'byok.$providerId';

  SecretStore get _store => ref.read(secretStoreProvider);

  @override
  Future<Map<String, String>> build() async {
    final out = <String, String>{};
    for (final p in byokProviders) {
      final key = await _store.read(storeKey(p.id));
      if (key != null && key.isNotEmpty) out[p.id] = key;
    }
    return out;
  }

  /// Saves [key] (trimmed) for [providerId]; an empty key removes it.
  Future<void> save(String providerId, String key) async {
    final k = key.trim();
    if (k.isEmpty) return remove(providerId);
    await _store.write(storeKey(providerId), k);
    state = AsyncData({...?state.value, providerId: k});
  }

  Future<void> remove(String providerId) async {
    await _store.delete(storeKey(providerId));
    state = AsyncData({...?state.value}..remove(providerId));
  }

  static String lastFour(String key) => key.length <= 4 ? key : key.substring(key.length - 4);
}

/// Which account each model bills to, as the user picked it in the shop
/// (model id → biller id). Models without a pick follow `ModelBilling.billerFor`.
final modelBillersProvider = NotifierProvider<ModelBillers, Map<String, String>>(ModelBillers.new);

final class ModelBillers extends Notifier<Map<String, String>> {
  static const _key = 'models.billers';

  Preferences get _prefs => ref.read(preferencesProvider);

  @override
  Map<String, String> build() {
    final raw = ref.watch(preferencesProvider)[_key];
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return {for (final e in decoded.entries) '${e.key}': '${e.value}'};
    } on FormatException {
      // Unreadable: start over.
    }
    return const {};
  }

  void set(ModelId model, Biller biller) {
    state = {...state, model.value: biller.id};
    _prefs[_key] = jsonEncode(state);
  }
}

/// Keys and picks together. Also published as `ModelBilling.current` for the
/// Code harness, which calls the gateway outside Riverpod.
final modelBillingProvider = Provider<ModelBilling>((ref) {
  final billing = ModelBilling(
    keys: ref.watch(byokKeysProvider).value ?? const {},
    choices: ref.watch(modelBillersProvider),
  );
  ModelBilling.current = billing;
  return billing;
});

/// The Ultra spend cap on the user's own key, in USD. Ultra on a key always
/// runs under a cap: the session's budget, or this one when it has none.
final byokUltraCapProvider = NotifierProvider<ByokUltraCap, double>(ByokUltraCap.new);

final class ByokUltraCap extends Notifier<double> {
  static const _key = 'byok.ultra_cap_usd';
  static const fallback = 25.0;

  @override
  double build() {
    final v = double.tryParse(ref.watch(preferencesProvider)[_key] ?? '');
    return v != null && v > 0 ? v : fallback;
  }

  void set(double usd) {
    if (usd <= 0) return;
    ref.read(preferencesProvider)[_key] = usd.toString();
    state = usd;
  }
}
