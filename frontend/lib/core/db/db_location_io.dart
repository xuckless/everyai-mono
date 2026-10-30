import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Documents everywhere (drift's default), except macOS: the app runs
/// unsandboxed there (the Code workspace spawns processes), where Documents
/// is the user's own ~/Documents. It uses Application Support instead, and
/// on first run copies over the database the sandboxed builds kept in the
/// container.
Future<Object> databaseDirectory() async {
  if (!Platform.isMacOS) return getApplicationDocumentsDirectory();
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  final target = File('${dir.path}/everyai.sqlite');
  final home = Platform.environment['HOME'];
  if (!await target.exists() && home != null && !home.contains('/Library/Containers/')) {
    final old = '$home/Library/Containers/dev.alidirect.everyai/Data/Documents/everyai.sqlite';
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$old$suffix');
      if (await f.exists()) await f.copy('${target.path}$suffix');
    }
  }
  return dir;
}
