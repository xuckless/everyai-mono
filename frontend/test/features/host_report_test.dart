import 'package:every_ai/features/code/host/host_report.dart';
import 'package:flutter_test/flutter_test.dart';

Uri _link({
  String title = 'check hangs',
  String tool = 'check',
  String expected = 'a result',
  String happened = 'it hung',
}) => reportIssueUri(
  title: title,
  tool: tool,
  expected: expected,
  happened: happened,
  harness: 'Claude Code',
  model: 'sonnet',
);

void main() {
  test('absolute paths are replaced, POSIX and Windows', () {
    final u = _link(happened: 'failed in /Users/ann/proj/lib/a.dart and C:\\Users\\ann\\proj\\a.dart, ~/work/x.txt');
    final body = u.queryParameters['body']!;
    expect(body, isNot(contains('ann')));
    expect(body, isNot(contains('a.dart')));
    expect(body, contains('<path>'));
  });

  test('the title is capped and an oversized body is cut under the link limit', () {
    final u = _link(title: 'x' * 500, happened: 'word ' * 5000, expected: 'é' * 3000);
    expect(u.queryParameters['title']!.length, lessThanOrEqualTo(121));
    expect(u.toString().length, lessThanOrEqualTo(7500));
    expect(u.queryParameters['body'], contains('…'));
  });
}
