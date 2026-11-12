import 'dart:io';

import 'package:every_ai/features/code/drivers/briefing/skill_export.dart';
import 'package:every_ai/features/skills/domain/skill_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import '_fixtures.dart';

/// Every path under [dir] with its size and mtime, links not followed.
Map<String, String> _snapshot(Directory dir) => {
  for (final e in dir.listSync(recursive: true, followLinks: false))
    e.path: '${e.statSync().size}:${e.statSync().modified.microsecondsSinceEpoch}',
};

void main() {
  late Directory tmp;
  late Directory src;
  late Directory outside;
  late String session;
  const sessionMd = 'hello\n';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('briefing_contain_');
    src = Directory('${tmp.path}/skills-src')..createSync();
    outside = Directory('${tmp.path}/outside')..createSync();
    File('${outside.path}/keep.txt').writeAsStringSync('mine');
    session = '${tmp.path}/session';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a briefing folder that is a link is refused and its target untouched', () async {
    Directory(session).createSync();
    Link('$session/briefing').createSync(outside.path);
    final before = _snapshot(outside);
    await expectLater(exportSkills(session, [writeSkill(src, 'alpha')], sessionText: sessionMd), throwsStateError);
    expect(_snapshot(outside), before);
    // Removing deletes the link, not what it points at.
    await removeBriefing(session);
    expect(Link('$session/briefing').existsSync(), isFalse);
    expect(_snapshot(outside), before);
  });

  test('a symlinked supporting file is skipped', () async {
    final s = writeSkill(src, 'alpha', files: {'references/ok.md': 'ok'});
    File('${outside.path}/secret.txt').writeAsStringSync('secret');
    Link('${s.dir}/references/leak.md').createSync('${outside.path}/secret.txt');
    final withLeak = InstalledSkill(
      dirName: s.dirName,
      dir: s.dir,
      source: s.source,
      manifest: s.manifest,
      report: s.report,
      digest: s.digest,
      files: ['references/leak.md', 'references/ok.md'],
    );
    final r = await exportSkills(session, [withLeak], sessionText: sessionMd);
    expect(File('$session/briefing/skills/alpha/references/leak.md').existsSync(), isFalse);
    expect(File('$session/briefing/skills/alpha/references/ok.md').existsSync(), isTrue);
    expect(r.skipped.single, contains('references/leak.md'));
  });

  test('a files entry with ".." or an absolute path is rejected', () async {
    final s = writeSkill(src, 'alpha');
    File('${src.path}/loose.txt').writeAsStringSync('loose');
    final bad = InstalledSkill(
      dirName: s.dirName,
      dir: s.dir,
      source: s.source,
      manifest: s.manifest,
      report: s.report,
      digest: s.digest,
      files: ['../loose.txt', '/etc/hosts', 'a/../../loose.txt'],
    );
    final r = await exportSkills(session, [bad], sessionText: sessionMd);
    expect(r.skipped, hasLength(3));
    expect(File('$session/briefing/skills/loose.txt').existsSync(), isFalse);
    expect(File('$session/briefing/skills/alpha/hosts').existsSync(), isFalse);
  });
}
