import 'package:flutter/foundation.dart';

import '../../models/domain/model_catalog.dart';
import '../../usage/usage_totals.dart';

enum Role { user, assistant, system }

/// How the assistant should answer. Search and Research need a backend with web
/// search; until then they are sent as hints and answered like Chat.
enum ChatMode {
  chat('Chat', 'Answer from the model alone'),
  search('Search', 'Search the web and cite sources'),
  research('Research', 'Multi-step research with a report');

  const ChatMode(this.label, this.description);
  final String label;
  final String description;
}

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

/// A web source the answer drew on (search modes). Cited in text as `[n]`.
@immutable
final class Source {
  const Source({required this.url, required this.title, this.snippet});

  final Uri url;
  final String title;
  final String? snippet;

  /// `en.wikipedia.org` → `wikipedia.org`
  String get site => url.host.replaceFirst(RegExp(r'^(www|en|m)\.'), '');

  Map<String, Object?> toJson() => {'url': '$url', 'title': title, 'snippet': snippet};

  static Source? fromJson(Object? json) => switch (json) {
    {'url': final String url, 'title': final String title} => Source(
      url: Uri.parse(url),
      title: title,
      snippet: json['snippet'] as String?,
    ),
    _ => null,
  };
}

/// Sources shown above an answer, in citation order (`[1]` is `sources[0]`).
final class SourcesPart extends MessagePart {
  const SourcesPart(this.sources);
  final List<Source> sources;
}

/// Suggested next questions shown under an answer.
final class FollowUpsPart extends MessagePart {
  const FollowUpsPart(this.questions);
  final List<String> questions;
}

/// The model's thinking before (or between) its answer, shown collapsed.
final class ReasoningPart extends MessagePart {
  const ReasoningPart(this.text);
  final String text;
}

/// A tool call the app renders by [toolName] (quiz, chart, artifact, …), in
/// its place among the message's text.
final class ToolCallPart extends MessagePart {
  const ToolCallPart({required this.toolName, required this.argumentsJson, this.resultJson, this.callId});
  final String toolName;
  final String argumentsJson;
  final String? resultJson;
  final String? callId;
}

final class ArtifactPart extends MessagePart {
  const ArtifactPart({required this.artifactId, required this.title, required this.kind});
  final String artifactId;
  final String title;
  final String kind;
}

/// Tokens and charge for the turn that produced this message (not rendered;
/// summed for the composer's meter).
final class UsagePart extends MessagePart {
  const UsagePart(this.totals);
  final UsageTotals totals;
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

  UsageTotals get usage => parts.whereType<UsagePart>().fold(UsageTotals.zero, (sum, p) => sum + p.totals);

  List<Source> get sources => parts.whereType<SourcesPart>().expand((p) => p.sources).toList(growable: false);

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
