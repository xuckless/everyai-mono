import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'db_location.dart';

part 'app_database.g.dart';

@DataClassName('ConversationRow')
class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get modelId => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('MessageRow')
@TableIndex(name: 'messages_by_conversation', columns: {#conversationId, #createdAt})
class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text().references(Conversations, #id, onDelete: KeyAction.cascade)();

  /// `user` | `assistant` | `system`
  TextColumn get role => text()();
  TextColumn get modelId => text().nullable()();

  /// `complete` | `failed` | `cancelled` (streaming messages are only persisted when they finish)
  TextColumn get status => text()();
  TextColumn get error => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('MessagePartRow')
class MessageParts extends Table {
  TextColumn get messageId => text().references(Messages, #id, onDelete: KeyAction.cascade)();
  IntColumn get idx => integer()();

  /// `text` | `image` | `tool_call` | `artifact`
  TextColumn get kind => text()();
  TextColumn get body => text().nullable()();
  TextColumn get blobId => text().nullable().references(Blobs, #id)();
  TextColumn get mimeType => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {messageId, idx};
}

/// Binary payloads (generated images, attachments). Kept in SQLite so the same
/// code runs natively and on the web (drift stores the database in OPFS there).
@DataClassName('BlobRow')
class Blobs extends Table {
  TextColumn get id => text()();
  BlobColumn get bytes => blob()();
  TextColumn get mimeType => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Models the user pinned to their library.
@DataClassName('LibraryModelRow')
class LibraryModels extends Table {
  TextColumn get modelId => text()();
  IntColumn get position => integer()();

  @override
  Set<Column<Object>> get primaryKey => {modelId};
}

@DataClassName('KeyValueRow')
class KeyValues extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

@DriftDatabase(tables: [Conversations, Messages, MessageParts, Blobs, LibraryModels, KeyValues])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _open());

  @override
  int get schemaVersion => 1;

  static QueryExecutor _open() => driftDatabase(
    name: 'everyai',
    native: const DriftNativeOptions(databaseDirectory: databaseDirectory),
    web: DriftWebOptions(sqlite3Wasm: Uri.parse('sqlite3.wasm'), driftWorker: Uri.parse('drift_worker.js')),
  );

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createSearchIndex();
    },
    beforeOpen: (details) async {
      // Foreign keys are per-connection in SQLite, so set them on every open.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Full-text index over text parts. FTS5 ships in the sqlite3 builds drift
  /// uses natively and on the web. If it's missing, search falls back to LIKE.
  Future<void> _createSearchIndex() async {
    try {
      await customStatement(
        "CREATE VIRTUAL TABLE message_search USING fts5(body, message_id UNINDEXED, tokenize='unicode61')",
      );
      await customStatement('''
        CREATE TRIGGER message_parts_ai AFTER INSERT ON message_parts WHEN new.kind = 'text' BEGIN
          INSERT INTO message_search(body, message_id) VALUES (new.body, new.message_id);
        END''');
      await customStatement('''
        CREATE TRIGGER message_parts_ad AFTER DELETE ON message_parts WHEN old.kind = 'text' BEGIN
          DELETE FROM message_search WHERE message_id = old.message_id;
        END''');
    } on Object {
      // No FTS5 in this sqlite build.
    }
  }

  Future<bool> get hasSearchIndex async {
    final row = await customSelect("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'message_search'")
        .getSingleOrNull();
    return row != null;
  }
}
