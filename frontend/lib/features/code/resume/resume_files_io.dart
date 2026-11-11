// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../drivers/detection/cli_scan.dart' show findCli;
import '../harness/everyai/shell_io.dart' show ShellEnv;

Future<Map<String, String>> resumeEnv() async {
  try {
    return (await ShellEnv.load()).env;
  } on Object {
    return Platform.environment;
  }
}

Future<String?> readSmallFile(String path, {required int maxBytes}) async {
  try {
    final f = File(path);
    if (await f.length() > maxBytes) return null;
    return await f.readAsString();
  } on Object {
    return null;
  }
}

Future<List<String>> filesIn(String dir, {required String suffix}) async {
  try {
    return [
      await for (final e in Directory(dir).list(followLinks: false))
        if (e is File && e.path.endsWith(suffix)) e.path,
    ];
  } on Object {
    return const [];
  }
}

Future<List<Map<String, Object?>>?> sqliteRows(String path, String sql, List<Object?> params) async {
  if (!File(path).existsSync()) return null;
  Database? db;
  try {
    // Read-only: the CLI owns this file. A busy writer (WAL) doesn't block readers.
    db = sqlite3.open(path, mode: OpenMode.readOnly);
    db.execute('PRAGMA busy_timeout = 2000');
    return [for (final row in db.select(sql, params)) Map<String, Object?>.of(row)];
  } on Object {
    return null;
  } finally {
    db?.close();
  }
}

Future<void> deletePath(String path) async {
  try {
    switch (FileSystemEntity.typeSync(path, followLinks: false)) {
      case FileSystemEntityType.directory:
        await Directory(path).delete(recursive: true);
      case FileSystemEntityType.notFound:
        return;
      default:
        await File(path).delete();
    }
  } on FileSystemException {
    // Gone already, or not ours to delete: the session stays hidden either way.
  }
}

Future<int?> runCli(String command, List<String> args, {required Duration timeout}) async {
  final path = await findCli(command);
  if (path == null) return null;
  try {
    final p = await Process.start(path, args, environment: await resumeEnv());
    p.stdout.drain<void>().ignore();
    p.stderr.drain<void>().ignore();
    return await p.exitCode.timeout(
      timeout,
      onTimeout: () {
        p.kill();
        return -1;
      },
    );
  } on Object {
    return null;
  }
}
