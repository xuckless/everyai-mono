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
}
