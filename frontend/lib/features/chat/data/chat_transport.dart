import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/net/api_client.dart';
import '../../../core/net/api_error.dart';
import '../../models/domain/model_catalog.dart';
import '../domain/message.dart';

/// What the client sends for one assistant turn.
@immutable
final class ChatRequest {
  const ChatRequest({
    required this.model,
    required this.prompt,
    this.history = const [],
    this.mode = ChatMode.chat,
    this.conversationId,
    this.toolsEnabled = true,
  });

  final ModelSpec model;
  final String prompt;
  final ChatMode mode;

  /// Prior turns, oldest first.
  final List<Message> history;

  /// Sent as `session` so usage can be attributed to the conversation.
  final String? conversationId;

  /// Lets the model use tools (artifacts, charts, quizzes, web fetch, images).
  final bool toolsEnabled;
}

/// Incremental output of one assistant turn.
sealed class ChatEvent {
  const ChatEvent();
}

final class TextDelta extends ChatEvent {
  const TextDelta(this.text);
  final String text;
}

/// The model's thinking, shown collapsed.
final class ReasoningDelta extends ChatEvent {
  const ReasoningDelta(this.text);
  final String text;
}

final class ImageOutput extends ChatEvent {
  const ImageOutput(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String mimeType;
}

/// New sources, to append after the ones already received.
final class SourcesFound extends ChatEvent {
  const SourcesFound(this.sources);
  final List<Source> sources;
}

/// A UI tool call (quiz, chart, artifact, …) for the app to render.
final class UiToolCall extends ChatEvent {
  const UiToolCall({required this.id, required this.name, required this.argumentsJson});
  final String id;
  final String name;
  final String argumentsJson;
}

enum ToolRunStatus { running, done, failed }

/// Progress of a tool the server runs itself (web_fetch, generate_image).
final class ToolProgress extends ChatEvent {
  const ToolProgress({required this.id, required this.name, required this.status, this.detail});
  final String id;
  final String name;
  final ToolRunStatus status;
  final String? detail;
}

/// Tokens and the charge for one upstream call (a turn may make several).
final class UsageReport extends ChatEvent {
  const UsageReport({
    required this.promptTokens,
    required this.completionTokens,
    required this.cachedTokens,
    required this.chargedMicros,
  });
  final int promptTokens;
  final int completionTokens;
  final int cachedTokens;

  /// What the user was charged, in millionths of a dollar.
  final int chargedMicros;
}

final class FollowUpsSuggested extends ChatEvent {
  const FollowUpsSuggested(this.questions);
  final List<String> questions;
}

final class TurnDone extends ChatEvent {
  const TurnDone();
}

/// Moves chat turns over the wire. Cancellation: complete [cancel] to abort the
/// HTTP request. The stream then ends with a [CancelledError].
abstract interface class ChatTransport {
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel});
}

/// Image-output models: `POST /v1/images` with the prompt, one image back.
final class ImageTransport implements ChatTransport {
  const ImageTransport(this._api, {this.authenticated = false});

  final ApiClient _api;
  final bool authenticated;

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) async* {
    final json = await _api.postJson(
      'v1/images',
      {'model': request.model.id.value, 'prompt': request.prompt},
      authenticated: authenticated,
      timeout: ApiClient.generationTimeout,
      cancel: cancel,
    );
    if (json case {'mime': final String mime, 'data': final String data}) {
      yield ImageOutput(base64Decode(data), mime);
      yield const TurnDone();
    } else {
      throw const ProtocolError('The image response had no image.');
    }
  }
}

/// Token streaming over Server-Sent Events: `POST /v1/chat/stream`.
/// The event contract is documented in backend-exp/README.md.
final class SseTransport implements ChatTransport {
  const SseTransport(this._api, {this.path = 'v1/chat/stream', this.authenticated = false});

  final ApiClient _api;
  final String path;
  final bool authenticated;

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) async* {
    final body = <String, Object?>{
      'model': request.model.id.value,
      'mode': request.mode.name,
      'tools_enabled': request.toolsEnabled,
      'session': ?request.conversationId,
      'messages': [
        for (final m in request.history)
          if (m.status == MessageStatus.complete && m.plainText.isNotEmpty)
            {'role': m.role.name, 'content': m.plainText},
        {'role': 'user', 'content': request.prompt},
      ],
    };

    await for (final event in _api.postSse(path, body, authenticated: authenticated, cancel: cancel)) {
      final Object? data;
      try {
        data = event.data.isEmpty ? const <String, Object?>{} : jsonDecode(event.data);
      } on FormatException {
        throw ProtocolError('Malformed ${event.event} event.');
      }
      switch ((event.event, data)) {
        case ('delta' || 'message', {'text': final String text}):
          yield TextDelta(text);
        case ('reasoning', {'text': final String text}):
          yield ReasoningDelta(text);
        case ('sources', {'sources': final List<Object?> list}):
          yield SourcesFound(list.map(Source.fromJson).nonNulls.toList(growable: false));
        case ('tool', {'id': final String id, 'name': final String name}):
          yield UiToolCall(id: id, name: name, argumentsJson: jsonEncode((data as Map)['arguments'] ?? const {}));
        case ('tool_status', {'id': final String id, 'name': final String name, 'status': final String status}):
          yield ToolProgress(
            id: id,
            name: name,
            status: ToolRunStatus.values.asNameMap()[status] ?? ToolRunStatus.running,
            detail: (data as Map)['detail'] as String?,
          );
        case ('image', {'mime': final String mime, 'data': final String b64}):
          yield ImageOutput(base64Decode(b64), mime);
        case ('usage', final Map<String, Object?> u):
          yield UsageReport(
            promptTokens: (u['prompt_tokens'] as num?)?.toInt() ?? 0,
            completionTokens: (u['completion_tokens'] as num?)?.toInt() ?? 0,
            cachedTokens: (u['cached_tokens'] as num?)?.toInt() ?? 0,
            chargedMicros: (u['charged_micros'] as num?)?.toInt() ?? 0,
          );
        case ('followups', {'questions': final List<Object?> list}):
          yield FollowUpsSuggested(list.whereType<String>().toList(growable: false));
        case ('done', _):
          yield const TurnDone();
          return;
        case ('error', {'message': final String message}):
          final status = ((data as Map)['status'] as num?)?.toInt();
          final retryable = data['retryable'] == true;
          throw HttpStatusError(status != null && status >= 400 ? status : (retryable ? 503 : 502), message);
        default:
          break; // Unknown events are ignored for forward compatibility.
      }
    }
    throw const ProtocolError('The stream ended before the response finished.');
  }
}

/// Picks the transport per model: image-output models go to `/v1/images`,
/// everything else streams.
final class TransportRouter implements ChatTransport {
  const TransportRouter({required this.stream, required this.image});

  final ChatTransport stream;
  final ChatTransport image;

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) =>
      (request.model.output == Modality.image ? image : stream).send(request, cancel: cancel);
}
