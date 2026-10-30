import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'db/app_database.dart';

/// Small key/value settings stored in the app database.
///
/// Values are loaded once before `runApp` (see `bootstrap`), so reads are synchronous.
/// Writes update memory immediately and persist in the background.
final class Preferences {
  Preferences._(this._db, this._values);

  static Future<Preferences> load(AppDatabase db) async {
    final rows = await db.select(db.keyValues).get();
    return Preferences._(db, {for (final r in rows) r.key: r.value});
  }

  /// Values kept in memory only, for tests.
  @visibleForTesting
  Preferences.inMemory([Map<String, String>? values]) : _db = null, _values = {...?values};

  final AppDatabase? _db;
  final Map<String, String> _values;

  String? operator [](String key) => _values[key];

  void operator []=(String key, String? value) {
    final db = _db;
    if (value == null) {
      _values.remove(key);
      if (db != null) unawaited((db.delete(db.keyValues)..where((r) => r.key.equals(key))).go());
    } else {
      _values[key] = value;
      if (db != null) {
        unawaited(db.into(db.keyValues).insertOnConflictUpdate(KeyValuesCompanion.insert(key: key, value: value)));
      }
    }
  }
}

/// Overridden in `bootstrap` with the loaded instance.
final preferencesProvider = Provider<Preferences>(
  (ref) => throw StateError('preferencesProvider must be overridden after Preferences.load'),
);
