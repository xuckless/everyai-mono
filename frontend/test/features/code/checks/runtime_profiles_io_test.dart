import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/checks/runtime_profiles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late String root;
  late String sessionDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('runtime-profiles');
    root = '${tmp.path}/proj';
    sessionDir = '${tmp.path}/session';
    Directory(root).createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a file git tracks came with the repository: not read and not written', () async {
    Process.runSync('git', ['init', '-q'], workingDirectory: root);
    Directory('$root/.everyai').createSync();
    final planted = File('$root/$runtimeProfilesPath')
      ..writeAsStringSync(
        jsonEncode({
          'commands': [
            {
              'command': 'make',
              'dir': '',
              'ms': [5000],
            },
          ],
        }),
      );
    Process.runSync('git', ['add', runtimeProfilesPath], workingDirectory: root);
    final before = planted.readAsStringSync();
    expect(await sessionRuntimeProfiles(sessionDir, root), isEmpty);
    await recordRuntime(root, 'cargo test', '', const Duration(seconds: 9));
    expect(planted.readAsStringSync(), before);
  });

  test('a linked .everyai/ or temp file is never written through', () async {
    final elsewhere = Directory('${tmp.path}/elsewhere')..createSync();
    Link('$root/.everyai').createSync(elsewhere.path);
    await recordRuntime(root, 'make', '', const Duration(seconds: 9));
    expect(elsewhere.listSync(), isEmpty);
    Link('$root/.everyai').deleteSync();
    Directory('$root/.everyai').createSync();
    final target = File('${tmp.path}/target.txt')..writeAsStringSync('keep');
    Link('$root/$runtimeProfilesPath.$pid.tmp').createSync(target.path);
    await recordRuntime(root, 'make', '', const Duration(seconds: 9));
    expect(target.readAsStringSync(), 'keep');
    expect(File('$root/$runtimeProfilesPath').existsSync(), isFalse);
  });

  test("a command with a value from the project's .env isn't kept", () async {
    File('$root/.env').writeAsStringSync('DEPLOY_TOKEN=zq81-hook-value\n');
    await recordRuntime(root, 'deploy zq81-hook-value', '', const Duration(seconds: 9));
    await recordRuntime(root, 'make', '', const Duration(seconds: 9));
    expect(await sessionRuntimeProfiles(sessionDir, root), ['`make`: ~9s (1 run)']);
  });
}
