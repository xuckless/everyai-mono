import 'dart:io';

/// Where a path the agent presented lives: absolute paths stay, relative
/// ones are under [workingDir].
String resolveDelivered(String workingDir, String path) {
  final p = path.startsWith('file://') ? Uri.parse(path).toFilePath() : path;
  final absolute = p.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p) || p.startsWith(r'\\');
  if (absolute) return p;
  final base = workingDir.endsWith('/') || workingDir.endsWith(r'\') ? workingDir : '$workingDir/';
  return base + (p.startsWith('./') ? p.substring(2) : p);
}

/// The command that shows [path] in the system file manager.
({String exe, List<String> args}) revealCommand(String path, {String? os}) {
  switch (os ?? Platform.operatingSystem) {
    case 'macos':
      return (exe: 'open', args: ['-R', path]);
    case 'windows':
      return (exe: 'explorer.exe', args: ['/select,${path.replaceAll('/', r'\')}']);
    default:
      final cut = path.lastIndexOf('/');
      return (exe: 'xdg-open', args: [cut > 0 ? path.substring(0, cut) : '/']);
  }
}

Future<void> revealDelivered(String path) async {
  final c = revealCommand(path);
  await Process.run(c.exe, c.args);
}
