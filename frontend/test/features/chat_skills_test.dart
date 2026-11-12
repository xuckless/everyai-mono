import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/security/untrusted.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/skills/data/skill_store_io.dart' as store;
import 'package:every_ai/features/skills/domain/chat_skills.dart';
import 'package:every_ai/features/skills/domain/skill_catalog.dart';
import 'package:every_ai/features/skills/domain/skill_format.dart';
import 'package:flutter_test/flutter_test.dart';

InstalledSkill _installed(
  String name, {
  SkillSource source = SkillSource.library,
  String? projectId,
  String description = 'Does a thing. Use it when asked.',
  String extra = '',
  List<SkillEntry> entries = const [SkillEntry('SKILL.md', size: 10)],
  List<String> files = const [],
}) {
  final md = '---\nname: $name\ndescription: $description\n$extra---\nBody of $name.\n';
  final c = checkSkill(dirName: name, skillMd: md, entries: entries);
  return InstalledSkill(
    dirName: name,
    dir: '/skills/${source.name}/$name',
    source: source,
    projectId: projectId,
    manifest: c.manifest,
    report: c.report,
    digest: 'd',
    files: files,
  );
}

ToolCallPart _call(String tool, Map<String, Object?> args, {SkillToolResult? result}) => ToolCallPart(
  toolName: tool,
  argumentsJson: jsonEncode(args),
  callId: 'c1',
  resultJson: result == null ? null : jsonEncode({'text': result.text, 'error': result.isError}),
);

void main() {
  group('which skills Chat offers', () {
    test('active library and shared skills only, sorted; project skills stay in Code', () {
      final all = [
        _installed('zeta'),
        _installed('alpha', source: SkillSource.shared),
        _installed('off'),
        _installed('repo', source: SkillSource.project, projectId: 'p1'),
      ];
      const settings = SkillSettings(disabled: {'library:off'}, trusted: {'project:p1:repo': 'd'});
      expect(chatSkills(all, settings).map((s) => s.name), ['alpha', 'zeta']);
    });
  });

  group('load_skill and read_skill_file', () {
    final files = <String, List<int>>{
      'references/style.md': utf8.encode('# Style\nShort titles.'),
      'assets/logo.png': [0x89, 0x50, 0x4e, 0x47, 0xff, 0xfe],
    };
    final deck = ChatSkill(
      name: 'make-deck',
      description: 'Plan a deck.',
      body: '# Make a deck\nOne idea per slide.',
      dir: '/lib/make-deck',
      files: files.keys.toList()..sort(),
    );
    const fill = ChatSkill(
      name: 'fill-pdf',
      description: 'Fill PDFs.',
      body: 'Run scripts/fill.py',
      dir: '/f',
      needsCode: true,
    );
    final reads = <String>[];
    final tools = SkillChatTools(
      [fill, deck],
      readFile: (dir, rel) async {
        reads.add('$dir/$rel');
        return files[rel];
      },
    );

    test('reads listed text files only, inside the folder', () async {
      reads.clear();
      final ok = await tools.run(readSkillFileTool, {'skill': 'make-deck', 'path': './references//style.md'});
      expect(ok.isError, isFalse);
      expect(
        ok.text,
        '<skill_file skill="make-deck" path="references/style.md">\n# Style\nShort titles.\n</skill_file>',
      );
      expect(reads, ['/lib/make-deck/references/style.md']);

      for (final bad in ['../other/SKILL.md', '/etc/passwd', r'references\style.md', 'C:/x', '']) {
        final r = await tools.run(readSkillFileTool, {'skill': 'make-deck', 'path': bad});
        expect(r.isError, isTrue, reason: bad);
      }
      final missing = await tools.run(readSkillFileTool, {'skill': 'make-deck', 'path': 'references/none.md'});
      expect(missing.text, contains('Its files: assets/logo.png, references/style.md'));
      final binary = await tools.run(readSkillFileTool, {'skill': 'make-deck', 'path': 'assets/logo.png'});
      expect(binary.text, contains('not a text file'));
      expect(reads, ['/lib/make-deck/references/style.md', '/lib/make-deck/assets/logo.png']);
      // SKILL.md itself is the instructions.
      final md = await tools.run(readSkillFileTool, {'skill': 'make-deck', 'path': 'SKILL.md'});
      expect(md.text, startsWith('<skill_content'));
      final script = await tools.run(readSkillFileTool, {'skill': 'fill-pdf', 'path': 'scripts/fill.py'});
      expect(script.isError, isTrue);
    });

    test('hidden characters never reach the model', () async {
      final md = '---\nname: sly\ndescription: Does\u200B a thing.\n---\nStep one.\u202E\nStep two.\n';
      final c = checkSkill(dirName: 'sly', skillMd: md, entries: const [SkillEntry('SKILL.md', size: 10)]);
      final skill = ChatSkill.of(
        InstalledSkill(
          dirName: 'sly',
          dir: '/lib/sly',
          source: SkillSource.library,
          manifest: c.manifest,
          report: c.report,
          digest: 'd',
          files: const ['references/a.md'],
        ),
      );
      final hidden = SkillChatTools([skill], readFile: (dir, rel) async => utf8.encode('Read this.\nThen\u200B that.'));
      final load = await hidden.run(loadSkillTool, {'name': 'sly'});
      expect(load.text, contains('Step one.\nStep two.'));
      expect(skill.description, 'Does a thing.');
      expect(hiddenIn(load.text), isEmpty);
      final read = await hidden.run(readSkillFileTool, {'skill': 'sly', 'path': 'references/a.md'});
      expect(
        read.text,
        '<skill_file skill="sly" path="references/a.md">\nRead this.\nThen that.\n</skill_file>\n'
        '[Hidden characters removed (zero-width characters) on line 2.]',
      );
      // Still recognised as a skill read in later turns.
      expect(skillCallNote(_call(readSkillFileTool, const {}, result: read)), read.text);
    });
  });

  group('reading from disk', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('chat_skills'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('files inside the folder only, no links out, size-capped', () async {
      final dir = Directory('${tmp.path}/deck')..createSync();
      File('${dir.path}/SKILL.md').writeAsStringSync('---\nname: deck\ndescription: d\n---\nBody\n');
      Directory('${dir.path}/references').createSync();
      File('${dir.path}/references/a.md').writeAsStringSync('hello');
      File('${tmp.path}/secret.txt').writeAsStringSync('secret');
      Link('${dir.path}/references/out.md').createSync('${tmp.path}/secret.txt');

      expect(utf8.decode((await store.readFile(dir.path, 'references/a.md', 1024))!), 'hello');
      expect(await store.readFile(dir.path, 'references/out.md', 1024), isNull);
      expect(await store.readFile(dir.path, '../secret.txt', 1024), isNull);
      expect(await store.readFile(dir.path, 'references/a.md', 2), isNull);

      final scanned = await store.scan((library: tmp.path, shared: null, projects: const []));
      final deck = scanned.singleWhere((s) => s.dirName == 'deck');
      expect(deck.files, ['references/a.md']);
    });
  });
}
