import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'dart:math';

class CacheSchema {
  // wtf even is this?
  static final CacheSchema instance = CacheSchema._internal();
  static Database? _database;

  // don't be fooled, this is a function.
  CacheSchema._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'app_data.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('PRAGMA foreign_keys = ON;');

    await db.execute(
      // imagine this is filled with create tables
      '''
      CREATE TABLE ChatInstances (
        ChatID INTEGER NOT NULL,                 -- Unique identifier for each chat
        MessageID INTEGER NOT NULL,              -- ID of the message (foreign key)
        FOREIGN KEY (MessageID) REFERENCES Messages(MessageID),
        PRIMARY KEY (ChatID, MessageID)          -- Composite primary key
      );
      '''
    );

    await db.execute(
      '''
      CREATE TABLE Messages (
        MessageID INTEGER PRIMARY KEY AUTOINCREMENT, -- Unique identifier for each message
        ModelID TEXT NOT NULL,                            -- ID of the model associated with the message
        Content TEXT NOT NULL,                       -- Content of the message
        IsSentByUser BOOLEAN NOT NULL,               -- Indicates if the message was sent by the user (1 for true, 0 for false)
        SentDate TEXT NOT NULL,                          -- Date the message was sent (format: YYYY-MM-DD)
        SentTime TEXT NOT NULL                           -- Time the message was sent (format: HH:MM:SS)
      );
      '''
    );
  }

  Future<int> insertChatInstance(int chatId, String modelId, String content, bool isSentByUser) async {
    final db = await database;
    final int messageId = await insertMessage(modelId, content, isSentByUser);
    
    final Map<String, dynamic> item = {'ChatID': chatId, 'MessageID': messageId};
    return await db.insert('ChatInstances', item);
  }

  Future<int> insertMessage(String modelId, String content, bool isSentByUser) async{
    final db = await database;
    final DateTime now = DateTime.now();
    final String date = now.toIso8601String().split('T')[0];
    final String time = now.toIso8601String().split('T')[1];
    final Map<String, dynamic> item = {
      'ModelID': modelId,
      'Content': content,
      'IsSentByUser': isSentByUser ? 1:0,
      'SentDate': date,
      'SentTime': time,
    };

    return await db.insert('Messages', item);
  }

  Future<List<Map<String, dynamic>>> fetchMessageContentByChatId(int chatId) async {
    final db = await database;

    // SQL query to join ChatInstances and Messages tables to fetch the content
    final List<Map<String, dynamic>> result = await db.rawQuery(
      '''
        SELECT Messages.Content as text, Messages.IsSentByUser as isSentByUser
        FROM ChatInstances
        INNER JOIN Messages ON ChatInstances.MessageID = Messages.MessageID
        WHERE ChatInstances.ChatID = ?
      ''', [chatId]
    );

    // Extract the content values from the query result
    return result;
  }

   Future<List<int>> fetchChatIDs() async{
    final db = await database;

    final List<Map<String, dynamic>> result = await db.rawQuery(
      '''
        SELECT DISTINCT ChatID
        FROM chatInstances;
      '''
    );
    return result.map((row) => row['ChatID'] as int).toList();
  }

  Future<bool> doesChatIdExist(int chatId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT 1 FROM ChatInstances WHERE ChatID = ?',
      [chatId],
    );
    return result.isNotEmpty;
  }

  Future<int> generateUniqueChatId() async {
    Random rand = Random();
    int chatId;

    do {
      chatId = rand.nextInt(100000000);
    } while (await doesChatIdExist(chatId));

    return chatId;
  }

  Future<void> deleteChatById(int chatId) async {
    final db = await database;

    await db.transaction((txn) async {
      // 1) Fetch all MessageIDs associated with this ChatID
      final messageIdRows = await txn.query(
        'ChatInstances',
        columns: ['MessageID'],
        where: 'ChatID = ?',
        whereArgs: [chatId],
      );

      // 2) Delete rows in ChatInstances for this ChatID
      await txn.delete(
        'ChatInstances',
        where: 'ChatID = ?',
        whereArgs: [chatId],
      );

      // 3) For each MessageID we just removed, check if it’s still used in ChatInstances.
      //    If not, delete it from Messages as well.
      for (final row in messageIdRows) {
        final int msgId = row['MessageID'] as int;

        // Check if any other ChatInstances references this same MessageID
        final usage = await txn.query(
          'ChatInstances',
          where: 'MessageID = ?',
          whereArgs: [msgId],
        );

        // If no rows reference it, we can safely delete from Messages
        if (usage.isEmpty) {
          await txn.delete(
            'Messages',
            where: 'MessageID = ?',
            whereArgs: [msgId],
          );
        }
      }
    });
  }

}