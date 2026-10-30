import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One model reply, assembled from the gateway's stream.
final class LlmReply {
  LlmReply({
    required this.text,
    required this.reasoning,
    required this.reasoningDetails,
    required this.toolCalls,
    required this.finishReason,
    this.promptTokens = 0,
  });

  final String text;
  final String reasoning;

  /// OpenRouter's structured reasoning (signed thinking blocks), sent back on
  /// the assistant message so the next call can continue from it.
  final List<Map<String, Object?>> reasoningDetails;
  final List<LlmToolCall> toolCalls;
  final String finishReason;

  /// Input tokens of this call: how full the context is.
  final int promptTokens;

  /// The assistant message to keep in the history.
  Map<String, Object?> toMessage() => {
    'role': 'assistant',
    'content': text,
    if (reasoningDetails.isNotEmpty) 'reasoning_details': reasoningDetails,
    if (toolCalls.isNotEmpty) 'tool_calls': [for (final c in toolCalls) c.toJson()],
  };
}

final class LlmToolCall {
  LlmToolCall({required this.id, required this.name, required this.arguments});

  final String id;
  final String name;

  /// The raw JSON text the model wrote.
  final String arguments;

  /// The arguments, or null when they aren't a JSON object (cut off, say).
  Map<String, Object?>? get args {
    try {
      final v = jsonDecode(arguments.isEmpty ? '{}' : arguments);
      return v is Map<String, Object?> ? v : null;
    } on FormatException {
      return null;
    }
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
  };
}

final class LlmError implements Exception {
  const LlmError(this.message, {this.status});
  final String message;
  final int? status;

  @override
  String toString() => message;
}

/// Calls the EveryAI gateway (`POST {base}/chat/completions`, OpenAI-style,
/// streamed). The gateway meters by `X-EveryAI-Session`, adds prompt-cache
/// breakpoints, applies `X-EveryAI-Effort` and recovers cut-off replies.
final class GatewayClient {
  GatewayClient({required this.baseUrl, required this.apiKey, http.Client? client}) : _http = client ?? http.Client();

  final String baseUrl;
  final String apiKey;
  final http.Client _http;

  Uri get _url => Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/chat/completions');

  Map<String, String> _headers(String sessionTag, String? effort) => {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
    'X-EveryAI-Session': sessionTag,
    'X-EveryAI-Effort': ?effort,
  };

  /// Streams one reply. [onText] and [onReasoning] get the deltas as they
  /// arrive; [cancel] completes to abandon the call.
  Future<LlmReply> complete({
    required String model,
    required List<Map<String, Object?>> messages,
    required List<Map<String, Object?>> tools,
    required String sessionTag,
    String? effort,
    int? maxTokens,
    String? toolChoice,
    void Function(String delta)? onText,
    void Function(String delta)? onReasoning,
    Future<void>? cancel,
  }) async {
    final req = http.Request('POST', _url)
      ..headers.addAll(_headers(sessionTag, effort))
      ..body = jsonEncode({
        'model': model,
        'stream': true,
        'messages': messages,
        if (tools.isNotEmpty) 'tools': tools,
        'tool_choice': ?toolChoice,
        'max_tokens': ?maxTokens,
      });
    final res = await _http.send(req);
    if (res.statusCode >= 300) {
      final body = await res.stream.bytesToString();
      throw LlmError(_errorText(body, res.statusCode), status: res.statusCode);
    }
    final text = StringBuffer();
    final reasoning = StringBuffer();
    final details = <int, Map<String, Object?>>{};
    final calls = <int, ({StringBuffer id, StringBuffer name, StringBuffer args})>{};
    var finish = '';
    var promptTokens = 0;
    var cancelled = false;
    final lines = res.stream.transform(utf8.decoder).transform(const LineSplitter());
    final done = Completer<void>();
    late final StreamSubscription<String> sub;
    unawaited(
      cancel?.then((_) {
        cancelled = true;
        unawaited(sub.cancel());
        if (!done.isCompleted) done.complete();
      }),
    );
    sub = lines.listen(
      (line) {
        if (!line.startsWith('data:')) return;
        final data = line.substring(5).trim();
        if (data.isEmpty || data == '[DONE]') return;
        final Object? json;
        try {
          json = jsonDecode(data);
        } on FormatException {
          return;
        }
        if (json is! Map<String, Object?>) return;
        if (json['error'] case final Map<String, Object?> e) {
          if (!done.isCompleted) done.completeError(LlmError('${e['message'] ?? e}'));
          return;
        }
        if (json['usage'] case {'prompt_tokens': final num p}) promptTokens = p.toInt();
        final choices = json['choices'];
        if (choices is! List || choices.isEmpty || choices.first is! Map) return;
        final choice = choices.first as Map<String, Object?>;
        if (choice['finish_reason'] case final String f when f.isNotEmpty) finish = f;
        final delta = choice['delta'];
        if (delta is! Map<String, Object?>) return;
        if (delta['content'] case final String c when c.isNotEmpty) {
          text.write(c);
          onText?.call(c);
        }
        final r = delta['reasoning'] ?? delta['reasoning_content'];
        if (r is String && r.isNotEmpty) {
          reasoning.write(r);
          onReasoning?.call(r);
        }
        if (delta['reasoning_details'] case final List<Object?> list) {
          for (final (i, item) in list.indexed) {
            if (item is! Map<String, Object?>) continue;
            mergeReasoningDetail(details, item, fallbackIndex: i);
          }
        }
        if (delta['tool_calls'] case final List<Object?> list) {
          for (final item in list) {
            if (item is! Map<String, Object?>) continue;
            final index = (item['index'] as num?)?.toInt() ?? calls.length;
            final slot = calls.putIfAbsent(
              index,
              () => (id: StringBuffer(), name: StringBuffer(), args: StringBuffer()),
            );
            if (item['id'] case final String id when id.isNotEmpty) {
              slot.id
                ..clear()
                ..write(id);
            }
            if (item['function'] case final Map<String, Object?> f) {
              if (f['name'] case final String n when n.isNotEmpty) slot.name.write(n);
              if (f['arguments'] case final String a) slot.args.write(a);
            }
          }
        }
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(LlmError('The connection to the model dropped: $e'));
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    await done.future;
    if (cancelled) throw const LlmCancelled();
    final keys = calls.keys.toList()..sort();
    return LlmReply(
      text: text.toString(),
      reasoning: reasoning.toString(),
      reasoningDetails: [for (final k in details.keys.toList()..sort()) details[k]!],
      toolCalls: [
        for (final (n, k) in keys.indexed)
          LlmToolCall(
            id: calls[k]!.id.isEmpty ? 'call_${DateTime.now().microsecondsSinceEpoch}_$n' : calls[k]!.id.toString(),
            name: calls[k]!.name.toString(),
            arguments: calls[k]!.args.toString(),
          ),
      ],
      finishReason: finish,
      promptTokens: promptTokens,
    );
  }

  /// A plain (not streamed) call, for search and the goal judge.
  Future<Map<String, Object?>> raw(Map<String, Object?> body, {required String sessionTag}) async {
    final res = await _http.post(_url, headers: _headers(sessionTag, null), body: jsonEncode(body));
    if (res.statusCode >= 300) throw LlmError(_errorText(res.body, res.statusCode), status: res.statusCode);
    final v = jsonDecode(res.body);
    if (v is! Map<String, Object?>) throw const LlmError('The model sent an unreadable reply.');
    return v;
  }

  static String _errorText(String body, int status) {
    try {
      final v = jsonDecode(body);
      if (v case {'error': {'message': final String m}}) return m;
      if (v case {'error': final String m}) return m;
    } on FormatException {
      // fall through
    }
    return 'The model call failed ($status): ${body.length > 300 ? '${body.substring(0, 300)}…' : body}';
  }

  void close() => _http.close();
}

/// The call was abandoned (Stop).
final class LlmCancelled implements Exception {
  const LlmCancelled();
}

/// Folds a streamed `reasoning_details` entry into [blocks]: entries with the
/// same index are one block, their `text`/`summary`/`data` concatenated and
/// other fields (type, signature, format, id) kept at their latest value
/// (as the gateway's own parser does).
void mergeReasoningDetail(Map<int, Map<String, Object?>> blocks, Map<String, Object?> item, {int fallbackIndex = 0}) {
  final index = (item['index'] as num?)?.toInt() ?? fallbackIndex;
  final block = blocks.putIfAbsent(index, () => <String, Object?>{});
  for (final MapEntry(:key, :value) in item.entries) {
    if (key == 'index') continue;
    if ((key == 'text' || key == 'summary' || key == 'data') && value is String) {
      block[key] = '${block[key] as String? ?? ''}$value';
    } else if (value != null) {
      block[key] = value;
    }
  }
}
