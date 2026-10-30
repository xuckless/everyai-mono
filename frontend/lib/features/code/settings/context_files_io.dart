import 'dart:io';

import 'context_files.dart';

ContextFs diskFs() => const _DiskFs();

String? homeDir() => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

final class _DiskFs implements ContextFs {
  const _DiskFs();

  /// Files larger than this are not instruction files anyone meant to load whole.
  static const _maxBytes = 1 << 20;

  @override
  Future<String?> read(String path) async {
    final f = File(path);
    try {
      if (!f.existsSync() || f.lengthSync() > _maxBytes) return null;
      return await f.readAsString().timeout(const Duration(seconds: 5));
    } on Object {
      return null;
    }
  }

  @override
  Future<bool> isDirectory(String path) => FileSystemEntity.isDirectory(path);
}
