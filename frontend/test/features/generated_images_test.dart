import 'dart:convert';
import 'dart:typed_data';

import 'package:every_ai/features/artifacts/domain/artifact.dart';
import 'package:every_ai/features/artifacts/export/downloads.dart';
import 'package:every_ai/features/attachments/attachment.dart';
import 'package:every_ai/features/chat/domain/image_refs.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:flutter_test/flutter_test.dart';

Message _msg(String id, Role role, List<MessagePart> parts) =>
    Message(id: id, conversationId: 'c', role: role, parts: parts, createdAt: DateTime(2026));

AttachmentPart _photo(String name, List<int> bytes) => AttachmentPart(
  name: name,
  mimeType: 'image/png',
  kind: AttachmentKind.image,
  size: bytes.length,
  bytes: Uint8List.fromList(bytes),
);

ImagePart _image(String id, {String? revises, String mime = 'image/png', List<int> bytes = const [1, 2, 3]}) =>
    ImagePart(bytes: Uint8List.fromList(bytes), mimeType: mime, imageId: id, prompt: 'a cat $id', revises: revises);

void main() {
  final history = [
    _msg('u1', Role.user, [
      _photo('cat.png', [9]),
      const TextPart('Make my cat a painting'),
    ]),
    _msg('a1', Role.assistant, [const TextPart('Here it is.'), _image('img_1')]),
    _msg('u2', Role.user, [const TextPart('Make it blue')]),
    _msg('a2', Role.assistant, [_image('img_2', revises: 'img_1')]),
    _msg('u3', Role.user, [
      _photo('dog.png', [8]),
      const TextPart('Now a poster'),
    ]),
    _msg('a3', Role.assistant, [
      _image('img_3', mime: 'image/svg+xml', bytes: utf8.encode('<svg viewBox="0 0 1 1"/>')),
      _image('img_4', revises: 'img_2'),
    ]),
  ];

  test('images get stable ids: uploads in attachment order, generated ones by their id', () {
    final refs = imageRefsIn(
      history,
      pending: [
        _photo('new.png', [7]),
      ],
    );
    expect(refs.map((r) => r.id), ['upload_1', 'img_1', 'img_2', 'upload_2', 'img_3', 'img_4', 'upload_3']);
    expect(refs.first.note, '[Image upload_1: cat.png]');
    expect(refs[2].note, '[Generated image img_2 (a new version of img_1): "a cat img_2"]');
    expect(refs[4].note, contains('(SVG)'));
    expect(refs.last.messageId, isNull);
    expect(refs.first.dataUrl, 'data:image/png;base64,${base64Encode([9])}');
    expect(nextImageId(refs), 'img_5');
    expect(nextImageId(const []), 'img_1');
  });

  test('image notes join each message\'s other notes', () {
    final notes = withImageNotes({'a1': '[Showed the user chart: X]'}, imageRefsIn(history));
    expect(notes['a1'], '[Showed the user chart: X]\n[Generated image img_1: "a cat img_1"]');
    expect(notes['u1'], '[Image upload_1: cat.png]');
    expect(notes.containsKey('u2'), isFalse);
  });

  test('the request carries the newest images\' bytes within the budget, older ones by id only', () {
    final refs = imageRefsIn(history);
    final one = refs.last.dataUrl!.length;
    final json = imageRefsJson(refs, budget: one + 1);
    expect(json.map((j) => j['id']), refs.map((r) => r.id));
    expect(json.where((j) => j['url'] != null).map((j) => j['id']), ['img_4']);
    expect(json.first.containsKey('url'), isFalse);
  });

  test('generated images are versioned artifacts; SVG ones render as illustrations', () {
    final artifacts = artifactsIn(history);
    final cat = artifacts.firstWhere((a) => a.id == 'img_1');
    expect(cat.versions.map((v) => v.callId), ['img_1', 'img_2', 'img_4']);
    expect(cat.latest.kind, VisualKind.image);
    expect(cat.latest.args['bytes'], isA<Uint8List>());
    final poster = artifacts.firstWhere((a) => a.id == 'img_3');
    expect(poster.versions.single.kind, VisualKind.svg);
    expect(poster.latest.args['svg'], '<svg viewBox="0 0 1 1"/>');
    expect(exportOf(poster.latest).extension, 'svg');
  });

  test('a raster image downloads as its own bytes', () async {
    final v = imageVisual(_image('img_9', mime: 'image/jpeg', bytes: [1, 2]));
    final options = downloadsOf(v);
    expect(options.single.extension, 'jpg');
    expect(await options.single.build(), [1, 2]);
  });
}
