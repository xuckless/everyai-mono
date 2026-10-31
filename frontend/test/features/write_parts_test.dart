import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late ToolRunner runner;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('parts');
    runner = ToolRunner(
      root: tmp.path,
      shell: SessionShell(root: tmp.path, sessionTag: 't', scratchDir: '${tmp.path}/.sh'),
      gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: ''),
      sessionTag: 't',
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a file is built in parts: write, then append, joined on line breaks', () async {
    final first = await runner.run('write', {'file_path': 'app.js', 'content': 'const a = 1;'});
    expect(first.text, contains('Created'));
    final second = await runner.run('write', {'file_path': 'app.js', 'content': 'const b = 2;\n', 'mode': 'append'});
    expect(second.text, 'Appended 1 lines to ${tmp.path}/app.js (now 2 lines).');
    expect(File('${tmp.path}/app.js').readAsStringSync(), 'const a = 1;\nconst b = 2;\n');
  });

  test('append creates a missing file; an unread existing file is refused', () async {
    await runner.run('write', {'file_path': 'new.txt', 'content': 'x\n', 'mode': 'append'});
    expect(File('${tmp.path}/new.txt').readAsStringSync(), 'x\n');
    File('${tmp.path}/old.txt').writeAsStringSync('mine\n');
    final out = await runner.run('write', {'file_path': 'old.txt', 'content': 'y\n', 'mode': 'append'});
    expect(out.isError, isTrue);
    expect(File('${tmp.path}/old.txt').readAsStringSync(), 'mine\n');
  });

  test('a very long single write still lands, with advice to split next time', () async {
    final big = List.generate(writePartLines * 2 + 1, (i) => 'line $i').join('\n');
    final out = await runner.run('write', {'file_path': 'big.html', 'content': big});
    expect(out.isError, isFalse);
    expect(out.text, contains('mode "append"'));
  });
}
