import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/checks/runtime_profiles.dart';
import 'package:every_ai/features/code/drivers/briefing/skill_export.dart' show removeBriefing;
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

  test('recordRuntime writes the project file', () async {
    await Future.wait([
      recordRuntime(root, 'flutter test', 'frontend/', const Duration(seconds: 10)),
      recordRuntime(root, 'flutter test', 'frontend/', const Duration(seconds: 20)),
    ]);
    final json = jsonDecode(File('$root/$runtimeProfilesPath').readAsStringSync());
    final e = RuntimeProfiles.fromJson(json).entries.values.single;
    expect(e.ms, [10000, 20000]);
    expect(e.runs, 2);
    expect(Directory('$root/.everyai').listSync().map((f) => f.path.split('/').last), ['runtime-profiles.json']);
  });

  test('the session snapshot is taken once and stays fixed', () async {
    await recordRuntime(root, 'make', '', const Duration(seconds: 30));
    final first = await sessionRuntimeProfiles(sessionDir, root);
    expect(first, ['`make`: ~30s (1 run)']);
    await recordRuntime(root, 'cargo test', '', const Duration(seconds: 90));
    expect(await sessionRuntimeProfiles(sessionDir, root), first);
    expect(await sessionRuntimeProfiles('${tmp.path}/other', root), hasLength(2));
  });

  test('no profiles: an empty snapshot', () async {
    expect(await sessionRuntimeProfiles(sessionDir, root), isEmpty);
    await recordRuntime(root, 'make', '', const Duration(seconds: 30));
    expect(await sessionRuntimeProfiles(sessionDir, root), isEmpty);
  });

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
    File('$root/.env').writeAsStringSync('DEPLOY_HOOK=zq81-hook-value\n');
    await recordRuntime(root, 'deploy zq81-hook-value', '', const Duration(seconds: 9));
    await recordRuntime(root, 'make', '', const Duration(seconds: 9));
    expect(await sessionRuntimeProfiles(sessionDir, root), ['`make`: ~9s (1 run)']);
  });

  test("removing an outside lead's briefing keeps the session's one rendering", () async {
    await recordRuntime(root, 'make', '', const Duration(seconds: 30));
    final first = await sessionRuntimeProfiles(sessionDir, root);
    await removeBriefing(sessionDir);
    await recordRuntime(root, 'cargo test', '', const Duration(seconds: 90));
    expect(await sessionRuntimeProfiles(sessionDir, root), first);
  });
}
