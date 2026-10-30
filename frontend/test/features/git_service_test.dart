import 'dart:io';

import 'package:every_ai/features/code/git/git_service.dart';
import 'package:flutter_test/flutter_test.dart';

Future<String> _git(String dir, List<String> args) async {
  final r = await Process.run('git', ['-C', dir, ...args]);
  if (r.exitCode != 0) fail('git ${args.join(' ')}: ${r.stderr}');
  return '${r.stdout}'.trim();
}

void main() {
  late Directory tmp;
  late String repo;
  late String hooks;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('everyai-git');
    repo = '${tmp.path}/app';
    hooks = '${tmp.path}/hooks';
    await Directory('$repo/lib').create(recursive: true);
    await _git(repo, ['init', '-q', '-b', 'main']);
    await _git(repo, ['config', 'user.name', 'Dev']);
    await _git(repo, ['config', 'user.email', 'dev@example.com']);
    File('$repo/lib/a.txt').writeAsStringSync('one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n');
    File('$repo/README.md').writeAsStringSync('# App\n');
    await _git(repo, ['add', '-A']);
    await _git(repo, ['commit', '-q', '-m', 'Initial commit']);
  });
  tearDown(() => tmp.delete(recursive: true));

  Future<SessionWorktree> start() => GitService.createWorktree(
    repoRoot: repo,
    slug: sessionSlug('Add a decrement method!', '01a18b2c-afed-74e3-b3b0-654b4168401e'),
    worktreesDir: '${tmp.path}/worktrees/app',
    hooksDir: hooks,
  );

  test('a session gets its own branch and checkout; the main checkout is untouched', () async {
    final w = await start();
    expect(w.branch, 'everyai/${w.slug}');
    expect(w.slug, startsWith('add-a-decrement-method-'));
    expect(w.baseBranch, 'main');
    expect(await _git(w.path, ['branch', '--show-current']), w.branch);
    File('${w.path}/lib/a.txt').writeAsStringSync('ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nTEN\n');
    File('${w.path}/lib/new.txt').writeAsStringSync('fresh\n');
    expect(File('$repo/lib/new.txt').existsSync(), isFalse);
    expect(await _git(repo, ['status', '--porcelain']), isEmpty);

    final changes = await GitService.changes(w);
    expect(
      {for (final c in changes) c.path: c.kind},
      {'lib/a.txt': ChangeKind.modified, 'lib/new.txt': ChangeKind.added},
    );
    // The diff includes the untracked file but leaves the real index alone.
    final diff = await GitService.diff(w);
    final a = diff.firstWhere((f) => f.path == 'lib/a.txt');
    expect(a.hunks, hasLength(2));
    expect(await _git(w.path, ['diff', '--cached', '--name-only']), isEmpty);

    // Reverting the second hunk keeps the first.
    await GitService.revertHunk(w, a, 1);
    expect(File('${w.path}/lib/a.txt').readAsStringSync(), startsWith('ONE\n'));
    expect(File('${w.path}/lib/a.txt').readAsStringSync(), endsWith('nine\nten\n'));
  });

  test('uncommitted changes, branch commits and the remote, for /commit and /pr', () async {
    final w = await start();
    expect(await GitService.uncommittedDiff(w), isEmpty);
    expect(await GitService.commitSubjects(w), isEmpty);
    expect(await GitService.remoteUrl(w), isEmpty);
    File('${w.path}/lib/new.txt').writeAsStringSync('fresh\n');
    expect([for (final f in await GitService.uncommittedDiff(w)) f.path], ['lib/new.txt']);
    expect(await GitService.commitAll(w, 'Add new.txt'), isTrue);
    expect(await GitService.uncommittedDiff(w), isEmpty);
    expect(await GitService.commitSubjects(w), ['Add new.txt']);
    // Still in the diff since the session's base.
    expect([for (final f in await GitService.diff(w)) f.path], ['lib/new.txt']);
    await _git(repo, ['remote', 'add', 'origin', 'git@github.com:acme/app.git']);
    expect(await GitService.remoteUrl(w), 'git@github.com:acme/app.git');
  });

  test('the commit hook strips AI credits and still runs the repo\'s own hook', () async {
    // The project's own commit-msg hook appends a marker.
    File('$repo/.git/hooks/commit-msg').writeAsStringSync('#!/bin/sh\necho "Reviewed-by: repo-hook" >> "\$1"\n');
    await Process.run('chmod', ['+x', '$repo/.git/hooks/commit-msg']);
    final w = await start();
    File('${w.path}/README.md').writeAsStringSync('# App\n\nMore.\n');
    await _git(w.path, ['add', '-A']);
    await _git(w.path, [
      'commit',
      '-q',
      '-m',
      'docs: expand the readme\n\nSays more.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n'
          'Co-authored-by: openhands <openhands@all-hands.dev>\nCo-Authored-By: Claude <noreply@anthropic.com>\n'
          'Co-authored-by: Sam <sam@example.com>',
    ]);
    final message = await _git(w.path, ['log', '-1', '--format=%B']);
    expect(message, contains('docs: expand the readme'));
    expect(message, contains('Co-authored-by: Sam <sam@example.com>'));
    expect(message, contains('Reviewed-by: repo-hook'));
    expect(message, isNot(contains('openhands')));
    expect(message, isNot(contains('Claude')));
    expect(await _git(w.path, ['log', '-1', '--format=%an']), 'Dev');
    // The main checkout keeps its normal hooks.
    expect(await Process.run('git', ['-C', repo, 'config', '--get', 'core.hooksPath']).then((r) => r.exitCode), 1);
  });

  test('checkpoints restore the working tree, untracked files included', () async {
    final w = await start();
    File('${w.path}/lib/new.txt').writeAsStringSync('turn one\n');
    final ref = await GitService.checkpoint(w, 2);
    File('${w.path}/lib/new.txt').writeAsStringSync('turn two\n');
    File('${w.path}/lib/a.txt').deleteSync();
    File('${w.path}/later.txt').writeAsStringSync('made later\n');
    await GitService.restoreCheckpoint(w, ref);
    expect(File('${w.path}/lib/new.txt').readAsStringSync(), 'turn one\n');
    expect(File('${w.path}/lib/a.txt').existsSync(), isTrue);
    expect(File('${w.path}/later.txt').existsSync(), isFalse);
    // HEAD and the index are untouched.
    expect(await _git(w.path, ['rev-parse', 'HEAD']), w.baseCommit);
  });

  test('squash merge lands one commit on the base branch, then the session is removed', () async {
    final w = await start();
    File('${w.path}/lib/new.txt').writeAsStringSync('feature\n');
    expect(await GitService.commitAll(w, 'wip'), isTrue);
    File('${w.path}/README.md').writeAsStringSync('# App\n\nDocs.\n');
    expect((await GitService.aheadBehind(w)).ahead, 1);

    // A dirty main checkout is refused.
    File('$repo/README.md').writeAsStringSync('dirty\n');
    await expectLater(GitService.squashMerge(w, 'feat: add new'), throwsA(isA<GitError>()));
    await _git(repo, ['checkout', '--', 'README.md']);

    final sha = await GitService.squashMerge(w, 'feat: add new');
    expect(await _git(repo, ['log', '-1', '--format=%H %s']), '$sha feat: add new');
    expect(await _git(repo, ['rev-list', '--count', 'HEAD']), '2');
    expect(File('$repo/lib/new.txt').readAsStringSync(), 'feature\n');
    expect(File('$repo/README.md').readAsStringSync(), contains('Docs.'));

    await GitService.checkpoint(w, 1);
    await GitService.removeWorktree(w, hooksDir: hooks);
    expect(Directory(w.path).existsSync(), isFalse);
    expect(await _git(repo, ['branch', '--list', w.branch]), isEmpty);
    expect(await _git(repo, ['for-each-ref', 'refs/everyai/']), isEmpty);
  });

  test('unified diffs parse into files and hunks', () {
    final files = parseUnifiedDiff(
      'diff --git a/x.txt b/x.txt\nindex 1..2 100644\n--- a/x.txt\n+++ b/x.txt\n@@ -1,2 +1,2 @@\n-a\n+b\n c\n'
      '@@ -10 +10 @@ ctx\n-y\n+z\ndiff --git a/n.txt b/n.txt\nnew file mode 100644\n--- /dev/null\n+++ b/n.txt\n'
      '@@ -0,0 +1 @@\n+hi\n',
    );
    expect(files.map((f) => f.path), ['x.txt', 'n.txt']);
    expect(files.first.hunks.map((h) => (h.oldStart, h.added, h.removed)), [(1, 1, 1), (10, 1, 1)]);
    expect(files.first.patchFor(1), contains('@@ -10 +10 @@ ctx\n-y\n+z\n'));
    expect(files.first.patchFor(1), isNot(contains('-a')));
  });

  test('AI credit lines are recognised, people are not', () {
    expect(
      stripBranding('fix: x\n\nbody\n\nCo-authored-by: openhands <openhands@all-hands.dev>\n'),
      'fix: x\n\nbody\n',
    );
    expect(stripBranding('fix: x\n\nCo-authored-by: Sam <sam@example.com>\n'), contains('Sam'));
    expect(stripBranding('Add y\n\nSigned-off-by: Dev <dev@example.com>\n'), contains('Signed-off-by: Dev'));
  });
}
