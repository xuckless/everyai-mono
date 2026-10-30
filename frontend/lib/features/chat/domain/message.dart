import 'package:flutter/foundation.dart';

import '../../models/domain/model_catalog.dart';

enum Role { user, assistant, system }

enum MessageStatus {
  /// Assistant message still receiving tokens.
  streaming,
  complete,
  failed,
  cancelled,
}

/// One piece of a message. Sealed, so renderers must handle every kind.
sealed class MessagePart {
  const MessagePart();
}

final class TextPart extends MessagePart {
  const TextPart(this.text);
  final String text;
}

/// Image bytes held in memory, or a reference to a blob in the store.
final class ImagePart extends MessagePart {
  const ImagePart({this.bytes, this.blobRef, this.mimeType = 'image/webp'}) : assert(bytes != null || blobRef != null);
  final Uint8List? bytes;
  final String? blobRef;
  final String mimeType;
}

/// Placeholders for the agentic roadmap (tools, artifacts). Not produced yet.
final class ToolCallPart extends MessagePart {
  const ToolCallPart({required this.toolName, required this.argumentsJson, this.resultJson});
  final String toolName;
  final String argumentsJson;
  final String? resultJson;
}

final class ArtifactPart extends MessagePart {
  const ArtifactPart({required this.artifactId, required this.title, required this.kind});
  final String artifactId;
  final String title;
  final String kind;
}

@immutable
final class Message {
  const Message({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.parts,
    required this.createdAt,
    this.model,
    this.status = MessageStatus.complete,
    this.error,
  });

  final String id;
  final String conversationId;
  final Role role;
  final List<MessagePart> parts;
  final DateTime createdAt;

  /// The model that actually produced this message (null for user messages).
  final ModelId? model;
  final MessageStatus status;
  final String? error;

  bool get isUser => role == Role.user;

  /// All text parts joined, for copy, search and titles.
  String get plainText => parts.whereType<TextPart>().map((p) => p.text).join('\n\n');

  Message copyWith({List<MessagePart>? parts, MessageStatus? status, String? error}) => Message(
    id: id,
    conversationId: conversationId,
    role: role,
    parts: parts ?? this.parts,
    createdAt: createdAt,
    model: model,
    status: status ?? this.status,
    error: error ?? this.error,
  );
}

@immutable
final class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.model,
    required this.createdAt,
    required this.updatedAt,
    this.pinned = false,
  });

  final String id;
  final String title;
  final ModelId model;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool pinned;
}
