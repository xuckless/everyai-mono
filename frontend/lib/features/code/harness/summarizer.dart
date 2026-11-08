import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/domain/model_catalog.dart' show ModelId;
import '../../../core/local_backend/local_gateway.dart';
import '../../settings/domain/byok_providers.dart' show ModelBilling;

import '../domain/compaction.dart';
import 'harness.dart' show HarnessError;

/// Writes a summary from chat messages (OpenAI format); returns the reply text.
typedef Summarizer = Future<String> Function(List<Map<String, Object?>> messages);

/// A [Summarizer] on the backend's OpenAI-compatible gateway ([baseUrl] ends
/// in `/v1`), billed to the session through `X-EveryAI-Session`.
///
/// When the gateway refuses [apiKey] (401), [onUnauthorized] is asked for a
/// new key and the call is tried once more with it.
Summarizer gatewaySummarizer({
  required String baseUrl,
  required String apiKey,
  required String sessionTag,
  String model = compactionModel,
  http.Client? client,
  Future<String> Function(String staleKey)? onUnauthorized,
}) {
  var key = apiKey;
  final once = _gatewayCall(baseUrl: baseUrl, sessionTag: sessionTag, model: model, client: client);
  return (messages) async {
    try {
      return await once(key, messages);
    } on HarnessError catch (e) {
      if (e.status != 401 || onUnauthorized == null) rethrow;
      key = await onUnauthorized(key);
      return once(key, messages);
    }
  };
}

Future<String> Function(String apiKey, List<Map<String, Object?>> messages) _gatewayCall({
  required String baseUrl,
  required String sessionTag,
  required String model,
  http.Client? client,
}) {
  return (apiKey, messages) async {
    final c = client ?? http.Client();
    try {
      final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
      // A model on the user's own key runs on the bundled server only (LocalGateway).
      final keys = ModelBilling.current.headersFor(ModelId(model));
      final local = keys.isEmpty ? null : await LocalGateway.resolve?.call();
      if (keys.isNotEmpty && local == null) throw const HarnessError(LocalGateway.missing);
      final res = await c
          .post(
            local == null ? Uri.parse('${base}chat/completions') : LocalGateway.completions(local),
            headers: {
              if (local == null) 'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
              'X-EveryAI-Session': sessionTag,
              if (local != null) ...LocalGateway.headers(local, keys),
            },
            body: jsonEncode({'model': model, 'messages': messages, 'max_tokens': 6000, 'stream': false}),
          )
          .timeout(const Duration(minutes: 3));
      if (res.statusCode >= 300) {
        throw HarnessError("Couldn't summarize the session (${res.statusCode}): ${res.body}", status: res.statusCode);
      }
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      if (json case {'choices': [{'message': {'content': final String text}}, ...]}) return text;
      throw const HarnessError("Couldn't summarize the session: the reply had no text.");
    } finally {
      if (client == null) c.close();
    }
  };
}
