import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/features/attachments/attachment.dart';
import 'package:every_ai/features/attachments/attachment_input.dart';
import 'package:every_ai/features/chat/data/chat_cleanup.dart';
import 'package:every_ai/features/chat/data/chat_repository.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('clipboard', () {
    test('a "/" or folder path next to copied text is not a file: the text pastes', () async {
      final files = await clipboardFiles(
        readFiles: () async => ['/', '/Users'],
        readImage: () async => null,
        readText: () async => 'const x = 1;',
      );
      expect(files, isEmpty);
    });
  });

  test('blob GC keeps referenced blobs and drops the rest', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = ChatRepository(db);
    await repo.createConversationWithId(id: 'c', title: 't', model: const ModelId('m'));
    await repo.saveMessage(
      Message(
        id: 'm1',
        conversationId: 'c',
        role: Role.user,
        createdAt: DateTime(2026),
        parts: [
          AttachmentPart(
            name: 'a.png',
            mimeType: 'image/png',
            kind: AttachmentKind.image,
            size: 3,
            bytes: Uint8List(3),
          ),
        ],
      ),
    );
    await db.into(db.blobs).insert(BlobsCompanion.insert(id: 'orphan', bytes: Uint8List(2), mimeType: 'image/png'));
    expect(await collectBlobGarbage(db), 1);
    expect((await db.select(db.blobs).get()).map((b) => b.id), isNot(contains('orphan')));
    expect(await db.select(db.blobs).get(), hasLength(1));
    // Deleting the chat orphans the rest.
    await repo.delete('c');
    expect(await collectBlobGarbage(db), 1);
    expect(await db.select(db.blobs).get(), isEmpty);
  });
}
