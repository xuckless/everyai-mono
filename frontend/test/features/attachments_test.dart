import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/features/attachments/attachment.dart';
import 'package:every_ai/features/chat/data/chat_repository.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/code/uploads/uploads.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  final haiku = ModelSpec.fromJson({
    'id': 'anthropic/claude-haiku-5.5',
    'name': 'Claude Haiku 5.5',
    'input_modalities': ['text', 'image', 'file'],
    'output_modalities': ['text'],
  })!;
  final textOnly = ModelSpec.fromJson({
    'id': 'dots-studio/dots-3-note-preview:free',
    'name': 'dots note',
    'input_modalities': ['text'],
    'output_modalities': ['text'],
  })!;

  test('kinds come from the extension, else from the bytes', () {
    expect(kindOf('a.PNG', Uint8List(4)), AttachmentKind.image);
    expect(kindOf('paper.pdf', Uint8List(4)), AttachmentKind.pdf);
    expect(kindOf('clip.wav', Uint8List(4)), AttachmentKind.audio);
    expect(kindOf('main.dart', bytes('void main() {}')), AttachmentKind.text);
    expect(kindOf('Makefile', bytes('all:\n\techo hi')), AttachmentKind.text);
    expect(kindOf('blob.bin', Uint8List.fromList([0, 1, 2, 255])), AttachmentKind.other);
  });

  test('size limits refuse rather than truncate', () {
    final big = Attachment.from(id: '1', name: 'notes.txt', bytes: Uint8List(300 * 1024));
    expect(big.attachment, isNull);
    expect(big.error, contains('too large'));
    final ok = Attachment.from(id: '2', name: 'x.png', bytes: Uint8List(1024));
    expect(ok.attachment!.mime, 'image/png');
  });

  test('models accept what their catalog modalities say; text goes everywhere', () {
    expect(haiku.inputs, {'text', 'image', 'file'});
    expect(haiku.accepts(AttachmentKind.pdf), isTrue);
    expect(haiku.accepts(AttachmentKind.audio), isFalse);
    expect(textOnly.accepts(AttachmentKind.text), isTrue);
    expect(textOnly.accepts(AttachmentKind.image), isFalse);
    final png = Attachment.from(id: '1', name: 'x.png', bytes: Uint8List(8)).attachment!;
    expect(png.unsupportedBy(textOnly), "dots note can't read images");
    expect(png.unsupportedBy(haiku), isNull);
    expect(modelForAll([AttachmentKind.image, AttachmentKind.pdf], [textOnly, haiku]), haiku);
    expect(modelForAll([AttachmentKind.audio], [textOnly, haiku]), isNull);
  });

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

  test('attachments are stored as blobs and come back with their bytes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = ChatRepository(db);
    await repo.createConversationWithId(id: 'c', title: 't', model: haiku.id);
    await repo.saveMessage(
      Message(
        id: 'm',
        conversationId: 'c',
        role: Role.user,
        createdAt: DateTime(2026),
        parts: [
          AttachmentPart(
            name: 'a.png',
            mimeType: 'image/png',
            kind: AttachmentKind.image,
            size: 3,
            bytes: bytes('img'),
          ),
          const TextPart('look'),
        ],
      ),
    );
    final [m] = await repo.messages('c');
    final [a] = m.attachments;
    expect((a.name, a.kind, a.size, utf8.decode(a.bytes!)), ('a.png', AttachmentKind.image, 3, 'img'));
    expect(m.plainText, 'look');
  });

  test('the Code attachments note round-trips', () {
    final message = 'Fix the layout\n\n${attachedNote(['.everyai/uploads/1-a.png', '.everyai/uploads/1-b.log'])}';
    final (text, paths) = splitAttachedNote(message);
    expect(text, 'Fix the layout');
    expect(paths, ['.everyai/uploads/1-a.png', '.everyai/uploads/1-b.log']);
    final (plain, none) = splitAttachedNote('no files');
    expect((plain, none.isEmpty), ('no files', true));
  });
}
