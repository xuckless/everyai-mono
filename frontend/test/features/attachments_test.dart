import 'dart:convert';
import 'dart:typed_data';

import 'package:every_ai/features/attachments/attachment.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  test('content parts: files first, text files inlined, the prompt last', () {
    final parts = messageContent('What are these?', [
      AttachmentPart(name: 'a.png', mimeType: 'image/png', kind: AttachmentKind.image, size: 3, bytes: bytes('img')),
      AttachmentPart(
        name: 'p.pdf',
        mimeType: 'application/pdf',
        kind: AttachmentKind.pdf,
        size: 3,
        bytes: bytes('pdf'),
      ),
      AttachmentPart(name: 'm.dart', mimeType: 'text/plain', kind: AttachmentKind.text, size: 4, bytes: bytes('code')),
    ]);
    expect(parts, [
      {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,aW1n'},
      },
      {
        'type': 'file',
        'file': {'filename': 'p.pdf', 'file_data': 'data:application/pdf;base64,cGRm'},
      },
      {'type': 'text', 'text': '<file name="m.dart">\ncode\n</file>'},
      {'type': 'text', 'text': 'What are these?'},
    ]);
    expect(messageContent('plain', const []), 'plain');
  });
}
