import 'dart:async';

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

  final AppDatabase _db;
  final Map<String, String> _values;

  String? operator [](String key) => _values[key];

  void operator []=(String key, String? value) {
    if (value == null) {
      _values.remove(key);
      unawaited((_db.delete(_db.keyValues)..where((r) => r.key.equals(key))).go());
    } else {
      _values[key] = value;
      unawaited(_db.into(_db.keyValues).insertOnConflictUpdate(KeyValuesCompanion.insert(key: key, value: value)));
    }
  }
}

/// Overridden in `bootstrap` with the loaded instance.
final preferencesProvider = Provider<Preferences>(
  (ref) => throw StateError('preferencesProvider must be overridden after Preferences.load'),
);
