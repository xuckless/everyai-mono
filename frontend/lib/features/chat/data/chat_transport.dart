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
  const ChatRequest({required this.model, required this.prompt, this.history = const [], this.mode = ChatMode.chat});

  final ModelSpec model;
  final String prompt;
  final ChatMode mode;

  /// Prior turns, oldest first. The current one-shot endpoints ignore this; the
  /// SSE contract carries it.
  final List<Message> history;
}

/// Incremental output of one assistant turn.
sealed class ChatEvent {
  const ChatEvent();
}

final class TextDelta extends ChatEvent {
  const TextDelta(this.text);
  final String text;
}

final class ImageOutput extends ChatEvent {
  const ImageOutput(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String mimeType;
}

final class SourcesFound extends ChatEvent {
  const SourcesFound(this.sources);
  final List<Source> sources;
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

/// One request, one response, for the backend's existing `/chat/{provider}` routes.
final class PostTransport implements ChatTransport {
  const PostTransport(this._api, {this.authenticated = false});

  final ApiClient _api;

  /// The current backend doesn't check auth on chat routes; flip this when it does.
  final bool authenticated;

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) async* {
    final body = <String, Object?>{'message': request.prompt, 'model': request.model.id.value};
    final endpoint = request.model.provider.endpoint;

    if (request.model.output == Modality.image) {
      final res = await _api.postForBytes(endpoint, body, authenticated: authenticated, cancel: cancel);
      if (!res.contentType.startsWith('image/')) {
        throw ProtocolError(_errorText(res.bytes) ?? 'Image generation failed.');
      }
      yield ImageOutput(res.bytes, res.contentType.split(';').first);
    } else {
      final json = await _api.postJson(
        endpoint,
        body,
        authenticated: authenticated,
        timeout: ApiClient.generationTimeout,
        cancel: cancel,
      );
      final text = json['message'];
      if (text is! String) throw const ProtocolError('Response had no "message".');
      yield TextDelta(text);
    }
    yield const TurnDone();
  }

  static String? _errorText(Uint8List bytes) {
    try {
      if (jsonDecode(utf8.decode(bytes)) case {'error': final String e}) return e;
    } on FormatException {
      // Binary body with a non-image content type.
    }
    return null;
  }
}

/// Token streaming over Server-Sent Events.
///
/// Contract (the backend implements it later; documented in AGENTS.md):
/// `POST /chat/stream` with `{"model", "provider", "messages": [{"role", "content"}]}`
/// and `Accept: text/event-stream`. Events:
/// - `event: delta`, `data: {"text": "..."}`
/// - `event: sources`, `data: {"sources": [{"url", "title", "snippet"?}]}`
/// - `event: followups`, `data: {"questions": ["..."]}`
/// - `event: done`, `data: {}`
/// - `event: error`, `data: {"message": "...", "retryable": bool}`
final class SseTransport implements ChatTransport {
  const SseTransport(this._api, {this.path = 'chat/stream', this.authenticated = false});

  final ApiClient _api;
  final String path;
  final bool authenticated;

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) async* {
    final body = <String, Object?>{
      'model': request.model.id.value,
      'provider': request.model.provider.name,
      'mode': request.mode.name,
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
        case ('sources', {'sources': final List<Object?> list}):
          yield SourcesFound(list.map(Source.fromJson).nonNulls.toList(growable: false));
        case ('followups', {'questions': final List<Object?> list}):
          yield FollowUpsSuggested(list.whereType<String>().toList(growable: false));
        case ('done', _):
          yield const TurnDone();
          return;
        case ('error', {'message': final String message}):
          throw HttpStatusError(502, message);
        default:
          break; // Unknown events are ignored for forward compatibility.
      }
    }
    throw const ProtocolError('The stream ended before the response finished.');
  }
}

/// Picks the transport per model: SSE when enabled and the model streams, POST otherwise.
final class TransportRouter implements ChatTransport {
  const TransportRouter({required this.post, required this.sse, required this.sseEnabled});

  final ChatTransport post;
  final ChatTransport sse;
  final bool sseEnabled;

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) =>
      (sseEnabled && request.model.supportsStreaming ? sse : post).send(request, cancel: cancel);
}
