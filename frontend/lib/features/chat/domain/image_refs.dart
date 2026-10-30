import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../attachments/attachment.dart';
import 'message.dart';

/// One image in a conversation, by the id the model uses for it: `img_<n>`
/// for generated images (the server numbers them) and `upload_<n>` for image
/// attachments (numbered here, in the order they were attached).
@immutable
final class ImageRef {
  const ImageRef({required this.id, required this.mimeType, required this.note, this.bytes, this.messageId});

  final String id;
  final String mimeType;
  final Uint8List? bytes;

  /// The message it belongs to; null for the attachments being sent now.
  final String? messageId;

  /// How the model sees it in the conversation text.
  final String note;

  String? get dataUrl => bytes == null ? null : 'data:$mimeType;base64,${base64Encode(bytes!)}';
}

/// The images in [history] (oldest first), then the image [pending]
/// attachments of the message being sent.
List<ImageRef> imageRefsIn(List<Message> history, {List<AttachmentPart> pending = const []}) {
  final out = <ImageRef>[];
  var uploads = 0;
  ImageRef upload(AttachmentPart a, String? messageId) {
    final id = 'upload_${++uploads}';
    return ImageRef(id: id, mimeType: a.mimeType, bytes: a.bytes, messageId: messageId, note: '[Image $id: ${a.name}]');
  }

  for (final m in history) {
    for (final part in m.parts) {
      switch (part) {
        case AttachmentPart(kind: AttachmentKind.image):
          out.add(upload(part, m.id));
        case ImagePart(:final imageId?):
          final details = [if (part.isSvg) 'SVG', if (part.revises case final r?) 'a new version of $r'];
          out.add(
            ImageRef(
              id: imageId,
              mimeType: part.mimeType,
              bytes: part.bytes,
              messageId: m.id,
              note:
                  '[Generated image $imageId${details.isEmpty ? '' : ' (${details.join(', ')})'}'
                  '${part.prompt == null ? '' : ': "${part.prompt}"'}]',
            ),
          );
        default:
          break;
      }
    }
  }
  for (final a in pending) {
    if (a.kind == AttachmentKind.image) out.add(upload(a, null));
  }
  return out;
}

/// The id the next generated image gets: one past the highest `img_<n>`.
String nextImageId(Iterable<ImageRef> refs) {
  var top = 0;
  for (final r in refs) {
    if (r.id.startsWith('img_')) top = max(top, int.tryParse(r.id.substring(4)) ?? 0);
  }
  return 'img_${top + 1}';
}

/// [notes] with each message's image notes appended (the model's view of
/// which images exist and their ids).
Map<String, String> withImageNotes(Map<String, String> notes, List<ImageRef> refs) {
  final out = {...notes};
  for (final r in refs) {
    final id = r.messageId;
    if (id == null) continue;
    out[id] = [?out[id], r.note].join('\n');
  }
  return out;
}

/// For each attached image whose bytes go in the request's messages (as an
/// `image_url` part), its position among those parts, by upload id. The
/// numbering follows [imageRefsIn]; the counting follows the transport,
/// which sends complete history messages and attachments that have bytes.
Map<String, int> uploadsInMessages(List<Message> history, {List<AttachmentPart> pending = const []}) {
  final out = <String, int>{};
  var uploads = 0;
  var parts = 0;
  void visit(AttachmentPart a, {required bool sent}) {
    if (a.kind != AttachmentKind.image) return;
    final id = 'upload_${++uploads}';
    if (sent && a.bytes != null) out[id] = parts++;
  }

  for (final m in history) {
    for (final part in m.parts) {
      if (part is AttachmentPart) visit(part, sent: m.status == MessageStatus.complete);
    }
  }
  for (final a in pending) {
    visit(a, sent: true);
  }
  return out;
}

/// The `images` field of a chat request: every ref by id. Refs already in
/// the messages ([inMessages], from [uploadsInMessages]) point at their part
/// instead of repeating the bytes. Others carry their bytes as data URLs, the
/// newest first, up to [budget] characters in all (older ones are listed
/// without, so the server can say why it can't use them).
List<Map<String, Object?>> imageRefsJson(
  List<ImageRef> refs, {
  Map<String, int> inMessages = const {},
  int budget = 8 * 1024 * 1024,
}) {
  var left = budget;
  final urls = <String, String>{};
  for (final r in refs.reversed) {
    if (inMessages.containsKey(r.id)) continue;
    final url = r.dataUrl;
    if (url == null || url.length > left) continue;
    left -= url.length;
    urls[r.id] = url;
  }
  return [
    for (final r in refs) {'id': r.id, 'url': ?urls[r.id], 'message_image': ?inMessages[r.id]},
  ];
}
