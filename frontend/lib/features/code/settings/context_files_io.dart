import 'dart:io';

import 'context_files.dart';

/// Reads instruction files from disk. A file is read only when its real
/// path (links followed) is inside one of [roots], or sits in the same
/// folder as the link for files in the [outer] folders.
ContextFs diskFs({List<String> roots = const [], List<String> outer = const []}) => _DiskFs(roots: roots, outer: outer);

String? homeDir() => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

final class _DiskFs implements ContextFs {
  _DiskFs({required this.roots, required List<String> outer}) : outer = {for (final o in outer) _trim(o)};

  final List<String> roots;
  final Set<String> outer;

  /// Files larger than this are not instruction files anyone meant to load whole.
  static const _maxBytes = 1 << 20;

  late final Future<List<String>> _realRoots = _resolveRoots();

  Future<List<String>> _resolveRoots() async => [for (final r in roots) ?await _real(Directory(r))];

  static String _trim(String p) => p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;

  static Future<String?> _real(FileSystemEntity e) async {
    try {
      return _trim(await e.resolveSymbolicLinks());
    } on Object {
      return null;
    }
  }

  Future<bool> _allowed(File f, String real) async {
    bool inside(String base) => real == base || real.startsWith('$base/');
    if ((await _realRoots).any(inside)) return true;
    final dir = _trim(f.parent.path);
    if (!outer.contains(dir)) return false;
    return File(real).parent.path == await _real(f.parent);
  }

  @override
  Future<String?> read(String path) async {
    final f = File(path);
    try {
      if (!f.existsSync()) return null;
      final real = await _real(f);
      if (real == null || !await _allowed(f, real)) return null;
      final target = File(real);
      if (target.lengthSync() > _maxBytes) return null;
      return await target.readAsString().timeout(const Duration(seconds: 5));
    } on Object {
      return null;
    }
  }

  @override
  Future<bool> isDirectory(String path) => FileSystemEntity.isDirectory(path);
}
