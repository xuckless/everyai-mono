import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../code/gateway_key.dart' show SecretStore, secretStoreProvider;
import 'domain/byok_providers.dart';

/// The user's own provider keys, kept in the system keychain under
/// `byok.<provider id>`. Nothing uses them yet (BYOK isn't wired to the
/// backend); the state holds only the last four characters of each.
final byokKeysProvider = AsyncNotifierProvider<ByokKeys, Map<String, String>>(ByokKeys.new);

final class ByokKeys extends AsyncNotifier<Map<String, String>> {
  static String storeKey(String providerId) => 'byok.$providerId';

  SecretStore get _store => ref.read(secretStoreProvider);

  @override
  Future<Map<String, String>> build() async {
    final out = <String, String>{};
    for (final p in byokProviders) {
      final key = await _store.read(storeKey(p.id));
      if (key != null && key.isNotEmpty) out[p.id] = lastFour(key);
    }
    return out;
  }

  /// Saves [key] (trimmed) for [providerId]; an empty key removes it.
  Future<void> save(String providerId, String key) async {
    final k = key.trim();
    if (k.isEmpty) return remove(providerId);
    await _store.write(storeKey(providerId), k);
    state = AsyncData({...?state.value, providerId: lastFour(k)});
  }

  Future<void> remove(String providerId) async {
    await _store.delete(storeKey(providerId));
    state = AsyncData({...?state.value}..remove(providerId));
  }

  static String lastFour(String key) => key.length <= 4 ? key : key.substring(key.length - 4);
}
