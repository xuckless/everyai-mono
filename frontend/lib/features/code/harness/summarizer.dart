import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/compaction.dart';
import 'openhands_harness.dart' show HarnessError;

/// Writes a summary from chat messages (OpenAI format); returns the reply text.
typedef Summarizer = Future<String> Function(List<Map<String, Object?>> messages);

/// A [Summarizer] on the backend's OpenAI-compatible gateway ([baseUrl] ends
/// in `/v1`), billed to the session through `X-EveryAI-Session`.
Summarizer gatewaySummarizer({
  required String baseUrl,
  required String apiKey,
  required String sessionTag,
  String model = compactionModel,
  http.Client? client,
}) {
  return (messages) async {
    final c = client ?? http.Client();
    try {
      final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
      final res = await c
          .post(
            Uri.parse('${base}chat/completions'),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
              'X-EveryAI-Session': sessionTag,
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
