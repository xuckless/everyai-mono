import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

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
    await db.execute(
      // imagine this is filled with create tables
      '''
      '''
    );

    await db.execute(
      '''
      '''
    );
  }
}