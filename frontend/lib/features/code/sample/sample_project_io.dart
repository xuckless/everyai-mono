import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/process/supervisor.dart' show ProbeOwner;
import '../drivers/short_run.dart';

Future<String> createSampleProject() async {
  final root = Directory('${(await getApplicationSupportDirectory()).path}/sample-projects');
  var dir = Directory('${root.path}/counter-app');
  for (var n = 2; await dir.exists(); n++) {
    dir = Directory('${root.path}/counter-app-$n');
  }
  final files = {
    'pubspec.yaml': 'name: counter_app\nenvironment:\n  sdk: ^3.9.0\ndev_dependencies:\n  test: ^1.25.0\n',
    'lib/counter.dart': 'class Counter {\n  int value = 0;\n  void increment() => value++;\n}\n',
    'test/counter_test.dart':
        "import 'package:counter_app/counter.dart';\nimport 'package:test/test.dart';\n\nvoid main() {\n"
        "  test('increment adds one', () {\n    final c = Counter()..increment();\n    expect(c.value, 1);\n  });\n}\n",
    '.gitignore': '.dart_tool/\npubspec.lock\n',
    'README.md':
        '# counter-app\n\nA tiny Dart package to try the EveryAI coding agent on. Run the tests with `dart test`.\n',
  };
  for (final MapEntry(:key, :value) in files.entries) {
    final f = File('${dir.path}/$key');
    await f.parent.create(recursive: true);
    await f.writeAsString(value);
  }
  Future<void> git(List<String> args) async {
    final r = await runShort(
      'git',
      ['-c', 'user.name=EveryAI', '-c', 'user.email=sample@everyai.invalid', ...args],
      timeout: const Duration(minutes: 1),
      cwd: dir.path,
      owner: const ProbeOwner('git'),
    );
    if (runProblem('git ${args.first}', r) case final why?) debugPrint(why);
  }

  await git(['init', '-q']);
  await git(['add', '-A']);
  await git(['commit', '-qm', 'Sample counter app']);
  return dir.path;
}
