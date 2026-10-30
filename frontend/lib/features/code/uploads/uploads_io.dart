import 'dart:io';

import '../../attachments/attachment.dart';
import '../settings/settings.dart';
import 'uploads.dart';

Future<List<String>> saveUploads(String workingDir, List<Attachment> files) async {
  final dir = Directory('$workingDir/$uploadsDir');
  await dir.create(recursive: true);
  await excludeFromGit(workingDir, const ['/$uploadsDir/', '/$localSettingsPath']);
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
