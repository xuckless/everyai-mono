import 'dart:io';

import '../../attachments/attachment.dart';
import 'uploads.dart';

Future<List<String>> saveUploads(String workingDir, List<Attachment> files) async {
  final dir = Directory('$workingDir/$uploadsDir');
  await dir.create(recursive: true);
  await _excludeFromGit(workingDir);
  final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '').substring(0, 14);
  final out = <String>[];
  for (final f in files) {
    final safe = f.name.replaceAll(RegExp(r'[/\\:\x00]'), '_');
    var name = '$stamp-$safe';
    for (var n = 2; File('${dir.path}/$name').existsSync(); n++) {
      name = '$stamp-$n-$safe';
    }
    await File('${dir.path}/$name').writeAsBytes(f.bytes);
    out.add('$uploadsDir/$name');
  }
  return out;
}

/// Adds `.everyai/` to `.git/info/exclude` so uploads never get committed.
Future<void> _excludeFromGit(String workingDir) async {
  final git = Directory('$workingDir/.git');
  if (!git.existsSync()) return;
  final exclude = File('${git.path}/info/exclude');
  final current = exclude.existsSync() ? await exclude.readAsString() : '';
  if (current.split('\n').any((l) => l.trim() == '.everyai/')) return;
  await exclude.parent.create(recursive: true);
  await exclude.writeAsString('${current.isEmpty || current.endsWith('\n') ? current : '$current\n'}.everyai/\n');
}
