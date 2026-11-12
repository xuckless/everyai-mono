import 'package:every_ai/features/code/domain/bug_check.dart';
import 'package:flutter_test/flutter_test.dart';

// What bug_check keeps about a bug, now that it runs without phases.

void main() {
  test('changed repro files: edited or gone count, files that only gained lines do not', () {
    final s = BugCheckState(reproFiles: {'t/a_test.sh': 'd1', 't/b_test.sh': 'd2', 't/c_test.sh': 'd3'});
    final before = {'t/b_test.sh': 'x\n'};
    final after = {'t/b_test.sh': 'x\ny\n'};
    expect(
      s.changedReproFiles(
        {'t/a_test.sh': 'd1', 't/b_test.sh': 'changed'},
        before: (p) => before[p],
        after: (p) => after[p],
      ),
      ['t/c_test.sh'],
    );
    expect(s.changedReproFiles({'t/a_test.sh': 'other', 't/b_test.sh': 'd2', 't/c_test.sh': 'd3'}), ['t/a_test.sh']);
  });
}
