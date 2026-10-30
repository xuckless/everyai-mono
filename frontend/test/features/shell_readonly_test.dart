import 'package:every_ai/features/code/domain/shell_readonly.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exploration commands from real sessions run without approval', () {
    const dir = '"/Users/ali/Library/Application Support/dev.alidirect.everyai/sample-projects/counter-app"';
    for (final c in [
      // From the sessions that went wrong (Plan mode refused all of these).
      'cd $dir && git status 2>/dev/null | head -5; find . -path ./node_modules -prune -o -type f -print '
          "| grep -v '/\\.git/' | head -100",
      'cat lib/counter.dart; echo ----; cat test/counter_test.dart; echo ----; cat README.md',
      'cd $dir && git status | head; find . -name "*.dart" | grep -v .dart_tool; cat AGENTS.md 2>/dev/null | head',
      // Everyday reading.
      'ls -la',
      'rg -n "class Counter" lib',
      "grep -rn 'decrement' lib test",
      "sed -n '1,80p' lib/main.dart",
      'nl -ba lib/counter.dart | sed -n 1,40p',
      'git log --oneline -10',
      'git --no-pager diff --stat HEAD~1',
      'git -C ../other show HEAD:pubspec.yaml',
      'git branch -a',
      'git remote -v',
      'tree -L 2 -I node_modules',
      'find . -name "*.dart" | xargs wc -l | sort -n | tail -5',
      'wc -l < lib/counter.dart',
      'head -c 400 pubspec.yaml 2>&1',
      'dart --version',
      'dart pub deps --style=compact',
      'npm ls --depth=0',
      "awk '{print \$1}' data.csv | sort | uniq -c",
      'ls lib/{a,b}.dart',
      r'FOO=1 printenv FOO',
      'cd lib && ls',
    ]) {
      expect(isReadOnlyShell(c), isTrue, reason: c);
    }
  });

  test('anything that writes, runs code or hides what it does needs approval', () {
    for (final c in [
      'rm -rf build',
      'ls; rm -rf build',
      'ls && touch x',
      'echo hi > notes.txt',
      'echo hi >> notes.txt',
      'cat a | tee b',
      "sed -i '' 's/a/b/' lib/a.dart",
      "sed -ni 's/a/b/p' lib/a.dart",
      "sed -n '1w out.txt' a",
      'find . -name "*.tmp" -delete',
      r'find . -exec rm {} \;',
      'xargs rm < files.txt',
      'git checkout -- .',
      'git commit -am wip',
      'git branch -D main',
      'git branch feature',
      'git stash',
      'git -c alias.x=!rm x',
      'git config user.name me',
      'npm install',
      'flutter test',
      'dart run',
      'python3 script.py',
      './build.sh',
      'cat \$(which foo)',
      'echo `whoami`',
      'cat <(ls)',
      'cat <<EOF\nx\nEOF',
      '(cd lib && rm a)',
      'sleep 100 &',
      "awk 'BEGIN{system(\"rm x\")}'",
      "awk '{print > \"out\"}' a",
      'sort -o out.txt in.txt',
      'env rm x',
      'command rm x',
      'timeout 5 rm x',
      "echo 'unterminated",
      '',
    ]) {
      expect(isReadOnlyShell(c), isFalse, reason: c);
    }
  });
}
