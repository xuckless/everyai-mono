import 'package:every_ai/features/code/ui/code_top_bar.dart';
import 'package:every_ai/features/code/ui/transcript/transcript_items.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('displayPath', () {
    test('is relative inside the session folder', () {
      expect(displayPath('/Users/a/proj/src/main.py', '/Users/a/proj'), 'src/main.py');
      expect(displayPath('/Users/a/proj/src/main.py', '/Users/a/proj/'), 'src/main.py');
      expect(displayPath('/Users/a/proj', '/Users/a/proj'), '.');
    });

    test('uses ~ under the home folder and leaves other paths alone', () {
      expect(displayPath('/Users/a/other/x.txt', '/Users/a/proj', home: '/Users/a'), '~/other/x.txt');
      expect(displayPath('/tmp/x.txt', '/Users/a/proj', home: '/Users/a'), '/tmp/x.txt');
      expect(displayPath('/Users/a/projector/x', '/Users/a/proj'), '/Users/a/projector/x');
    });
  });

  test('the header drops chips by the width it has', () {
    expect(TopBarTier.forWidth(1400), TopBarTier.wide);
    expect(TopBarTier.forWidth(900), TopBarTier.medium);
    expect(TopBarTier.forWidth(700), TopBarTier.narrow);
  });
}
