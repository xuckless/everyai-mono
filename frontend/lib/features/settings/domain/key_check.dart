import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'byok_providers.dart';

/// A key check's outcome: [valid] true (accepted), false (rejected) or null
/// (couldn't tell: offline, provider down), with what to tell the user.
typedef KeyCheck = ({bool? valid, String message});

/// Checks keys; overridden in tests.
final keyCheckProvider = Provider<Future<KeyCheck> Function(ByokProvider provider, String key)>(
  (ref) => checkProviderKey,
);

/// Asks the provider whether [key] works, with a free read-only call. The
/// key goes only to that provider.
Future<KeyCheck> checkProviderKey(ByokProvider provider, String key, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final res = await switch (provider.id) {
      'openrouter' => c.get(Uri.parse('https://openrouter.ai/api/v1/key'), headers: {'Authorization': 'Bearer $key'}),
      'anthropic' => c.get(
        Uri.parse('https://api.anthropic.com/v1/models?limit=1'),
        headers: {
          'x-api-key': key,
          'anthropic-version': '2026-10-21',
          // Browsers need the opt-in; the key is the user's own.
          if (kIsWeb) 'anthropic-dangerous-direct-browser-access': 'true',
        },
      ),
      _ => throw ArgumentError('No check for ${provider.id}'),
    }.timeout(const Duration(seconds: 15));
    return switch (res.statusCode) {
      // Rate limited still means the key was accepted.
      200 || 429 => (valid: true, message: '${provider.name} key works'),
      401 || 403 => (valid: false, message: '${provider.name} rejected this key.'),
      final s => (valid: null, message: '${provider.name} answered $s. Try again in a moment.'),
    };
  } on TimeoutException {
    return (valid: null, message: '${provider.name} did not answer.');
  } on http.ClientException catch (e) {
    return (valid: null, message: 'Could not reach ${provider.name}: ${e.message}');
  } finally {
    if (client == null) c.close();
  }
}
