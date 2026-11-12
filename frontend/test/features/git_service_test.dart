import 'dart:io';

import 'package:every_ai/features/code/git/git_service.dart';
import 'package:every_ai/features/code/git/git_service_io.dart' show runGit;
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

  test('a commit with paths leaves other work alone; nothing to commit does not switch branches', () async {
    final w = await start();
    File('${w.path}/lib/mine.txt').writeAsStringSync('wip\n');
    File('${w.path}/lib/new.txt').writeAsStringSync('fresh\n');
    final tree = await GitService.snapshotTree(w);
    File('${w.path}/lib/new.txt').writeAsStringSync('fresh, changed\n');
    File('${w.path}/lib/more.txt').writeAsStringSync('more\n');
    expect((await GitService.changedSince(w, tree))..sort(), ['lib/more.txt', 'lib/new.txt']);
    final later = await GitService.snapshotTree(w);
    expect((await GitService.changedBetween(w, tree, later))..sort(), ['lib/more.txt', 'lib/new.txt']);
    expect(await GitService.changedBetween(w, later, later), isEmpty);
    // From the base commit: everything the session has done.
    expect((await GitService.changedBetween(w, w.baseCommit, later))..sort(), [
      'lib/mine.txt',
      'lib/more.txt',
      'lib/new.txt',
    ]);
    expect(await GitService.isDirtyAmong(w, ['lib/new.txt']), isTrue);
    expect(await GitService.isDirtyAmong(w, []), isFalse);

    expect(await GitService.commitAll(w, 'Just new', paths: ['lib/new.txt']), isTrue);
    expect(await _git(w.path, ['show', '--name-only', '--format=', 'HEAD']), 'lib/new.txt');
    expect(await GitService.isDirtyAmong(w, ['lib/new.txt']), isFalse);
    expect(await _git(w.path, ['status', '--porcelain']), contains('lib/mine.txt'));

    // Nothing of those paths is left: the branch is not created and the checkout stays.
    expect(await GitService.commitOnNewBranch(w, 'everyai/none', 'x', paths: ['lib/new.txt']), isNull);
    expect(await _git(w.path, ['branch', '--show-current']), w.branch);
    expect(await _git(w.path, ['branch', '--list', 'everyai/none']), isEmpty);
    final sha = await GitService.commitOnNewBranch(w, 'everyai/more', 'More', paths: ['lib/more.txt']);
    expect(sha, await _git(w.path, ['rev-parse', 'HEAD']));
    expect(await _git(w.path, ['show', '--name-only', '--format=', 'HEAD']), 'lib/more.txt');
  });

  test('a commit that fails after the switch goes back and removes the new branch', () async {
    final w = await start();
    File('${w.path}/lib/new.txt').writeAsStringSync('fresh\n');
    // EveryAI's commits run no hooks, so the failure is git's own: an empty author name.
    await _git(repo, ['config', 'user.name', '']);
    await expectLater(GitService.commitOnNewBranch(w, 'everyai/hooked', 'x'), throwsA(isA<GitError>()));
    expect(await _git(w.path, ['branch', '--show-current']), w.branch);
    expect(await _git(w.path, ['branch', '--list', 'everyai/hooked']), isEmpty);
    expect(await GitService.isDirty(w), isTrue);
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

  test('merge fast-forwards the base branch to the prepared commit, then the session is removed', () async {
    final w = await start();
    File('${w.path}/lib/new.txt').writeAsStringSync('feature\n');
    File('${w.path}/README.md').writeAsStringSync('# App\n\nDocs.\n');
    expect(await GitService.commitAll(w, 'feat: add new'), isTrue);
    expect((await GitService.aheadBehind(w)).ahead, 1);
    final candidate = await GitService.mergeCandidate(w);
    expect(candidate.subject, 'feat: add new');

    // A dirty main checkout is refused.
    File('$repo/README.md').writeAsStringSync('dirty\n');
    await expectLater(GitService.fastForwardMerge(w, candidate.sha), throwsA(isA<GitError>()));
    await _git(repo, ['checkout', '--', 'README.md']);

    // A commit the agent made after the user confirmed doesn't come along.
    File('${w.path}/later.txt').writeAsStringSync('later\n');
    expect(await GitService.commitAll(w, 'later'), isTrue);

    // An untracked file the merge would overwrite is git's error, not "base moved".
    File('$repo/lib/new.txt').writeAsStringSync('mine\n');
    await expectLater(
      GitService.fastForwardMerge(w, candidate.sha),
      throwsA(isA<GitError>().having((e) => e is BaseMoved, 'base moved', isFalse)),
    );
    File('$repo/lib/new.txt').deleteSync();

    final sha = await GitService.fastForwardMerge(w, candidate.sha);
    expect(sha, candidate.sha);
    expect(File('$repo/later.txt').existsSync(), isFalse);
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

  test('a fork works on a copy of the uncommitted folder and merges back file by file', () async {
    // Uncommitted work in the parent, and a dependency folder.
    File('$repo/lib/a.txt').writeAsStringSync('ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n');
    File('$repo/lib/draft.txt').writeAsStringSync('draft\n');
    Directory('$repo/node_modules/x').createSync(recursive: true);
    File('$repo/.gitignore').writeAsStringSync('node_modules/\n');
    final copy = (await GitService.forkCopy('$repo/lib', worktreesDir: '${tmp.path}/forks', slug: 'f1'))!;
    expect(copy.path, endsWith('/f1/lib'));
    expect(File('${copy.path}/a.txt').readAsStringSync(), startsWith('ONE'));
    expect(File('${copy.path}/draft.txt').existsSync(), isTrue);
    expect(copy.links, ['node_modules']);
    expect(Link('${copy.root}/node_modules').existsSync(), isTrue);

    // The fork changes the end of a.txt and adds a file; meanwhile the parent changes the start again.
    File('${copy.path}/a.txt').writeAsStringSync('ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nTEN\n');
    File('${copy.path}/new.txt').writeAsStringSync('from the fork\n');
    File('$repo/lib/a.txt').writeAsStringSync('ONE!\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n');
    // And both change draft.txt: a conflict.
    File('${copy.path}/draft.txt').writeAsStringSync('fork draft\n');
    File('$repo/lib/draft.txt').writeAsStringSync('parent draft\n');

    final result = await GitService.mergeFork(copy, slug: 'f1');
    expect(result.merged, unorderedEquals(['lib/a.txt', 'lib/new.txt']));
    expect(result.conflicts, ['lib/draft.txt']);
    expect(File('$repo/lib/a.txt').readAsStringSync(), startsWith('ONE!\n'));
    expect(File('$repo/lib/a.txt').readAsStringSync(), endsWith('TEN\n'));
    expect(File('$repo/lib/new.txt').readAsStringSync(), 'from the fork\n');
    expect(File('$repo/lib/draft.txt').readAsStringSync(), contains('<<<<<<< yours'));
    // The worktree is gone, the work kept under a ref, the user's branch and index untouched.
    expect(Directory(copy.root).existsSync(), isFalse);
    expect(await _git(repo, ['rev-parse', '--verify', '-q', result.ref]), isNotEmpty);
    expect(await _git(repo, ['log', '--format=%s', '-1']), 'Initial commit');
    expect(await _git(repo, ['diff', '--cached', '--name-only']), isEmpty);
  });

  group('landing a workflow with its lanes\' commits', () {
    /// A lane: a fork of the folder that commits [commits] (path → content, message) as [author], then merges back.
    Future<LaneRef> lane(String slug, List<(Map<String, String>, String)> commits, {String author = 'Lane'}) async {
      final copy = (await GitService.forkCopy(repo, worktreesDir: '${tmp.path}/forks', slug: slug))!;
      for (final (files, message) in commits) {
        files.forEach(
          (p, text) => File('${copy.root}/$p')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(text),
        );
        await _git(copy.root, ['add', '-A']);
        await _git(copy.root, [
          '-c',
          'user.name=$author',
          '-c',
          'user.email=$author@example.com',
          'commit',
          '-q',
          '-m',
          message,
        ]);
      }
      final m = await GitService.mergeFork(copy, slug: slug);
      return (ref: m.ref, base: copy.base, label: slug);
    }

    SessionWorktree here() =>
        SessionWorktree(repoRoot: repo, path: repo, branch: 'main', baseBranch: 'main', baseCommit: 'HEAD');

    test('the repository\'s index hook and clean filter never run while landing', () async {
      final marker = '${tmp.path}/ran';
      final a = await lane('a', [
        ({'lib/h.txt': 'h\n'}, 'Add h'),
      ]);
      // After the lane: its own commits (the test's plain git) would run it.
      final hook = File('$repo/.git/hooks/post-index-change')..writeAsStringSync('#!/bin/sh\ntouch "$marker"\n');
      await Process.run('chmod', ['+x', hook.path]);
      File('$repo/lib/glue.txt').writeAsStringSync('glue\n');
      final landed = await GitService.landWithCommits(
        here(),
        lanes: [a],
        paths: ['lib/h.txt', 'lib/glue.txt'],
        message: 'Integrate',
      );
      expect(landed.head, isNotNull);
      expect(File(marker).existsSync(), isFalse);
      // A clean filter: storing the files would need it, so landing is refused and it doesn't run.
      await _git(repo, ['config', 'filter.mark.clean', 'touch "$marker"; cat']);
      File('$repo/.gitattributes').writeAsStringSync('*.txt filter=mark\n');
      File('$repo/lib/glue.txt').writeAsStringSync('glue 2\n');
      final before = await _git(repo, ['rev-parse', 'HEAD']);
      await expectLater(
        GitService.landWithCommits(here(), lanes: [a], paths: ['lib/glue.txt'], message: 'Again'),
        throwsA(isA<GitError>()),
      );
      expect(File(marker).existsSync(), isFalse);
      expect(await _git(repo, ['rev-parse', 'HEAD']), before);
    });
  });

  group('a repository that defines programs', () {
    late String marks;

    // Git as the test's own setup, with the repository's programs off.
    Future<String> safe(String dir, List<String> args) => _git(dir, [
      '-c',
      'core.hooksPath=/dev/null',
      '-c',
      'core.fsmonitor=false',
      '-c',
      'filter.s.smudge=',
      '-c',
      'hook.x.enabled=false', //
      ...args,
    ]);

    /// Makes [repo] hostile: every program git might run writes its name into [marks].
    Future<String> arm() async {
      marks = '${tmp.path}/marks.log';
      final evil = File('${tmp.path}/evil.sh')..writeAsStringSync('#!/bin/sh\necho "\$1" >> "$marks"\n');
      await Process.run('chmod', ['+x', evil.path]);
      final run = evil.path;
      for (final (k, v) in [
        ('core.fsmonitor', '$run fsmonitor'),
        ('diff.y.textconv', '$run textconv'),
        ('diff.external', '$run external'),
        ('merge.m.driver', '$run merge'),
        ('filter.s.smudge', '$run smudge'),
        ('log.showSignature', 'true'),
        ('gpg.program', '$run gpg'),
        ('core.sshCommand', '$run ssh'),
        ('credential.helper', '!$run credential'),
        // A hook set in config (git 2.54) runs whatever hooksPath says.
        ('hook.x.command', '"$run" config-hook'),
      ]) {
        await _git(repo, ['config', k, v]);
      }
      for (final event in [
        'reference-transaction',
        'pre-commit',
        'post-commit',
        'post-checkout',
        'post-index-change',
      ]) {
        await _git(repo, ['config', '--add', 'hook.x.event', event]);
      }
      for (final name in [
        'pre-commit',
        'commit-msg',
        'post-commit',
        'post-checkout',
        'reference-transaction',
        'pre-push',
        'post-merge',
        'post-index-change',
      ]) {
        final hook = File('$repo/.git/hooks/$name')..writeAsStringSync('#!/bin/sh\n"$run" hook-$name\n');
        await Process.run('chmod', ['+x', hook.path]);
      }
      return run;
    }

    test('EveryAI\'s own git work runs none of them', () async {
      File('$repo/.gitattributes').writeAsStringSync('*.txt diff=y merge=m filter=s\n');
      await _git(repo, ['add', '-A']);
      await _git(repo, ['commit', '-q', '-m', 'Attributes']);
      final remote = '${tmp.path}/remote.git';
      await _git(tmp.path, ['init', '-q', '--bare', remote]);
      await _git(repo, ['remote', 'add', 'origin', remote]);
      final run = await arm();
      await _git(repo, ['config', 'remote.origin.receivepack', '$run receivepack; git-receive-pack']);
      final hook = File('$remote/hooks/pre-receive')..writeAsStringSync('#!/bin/sh\n"$run" hook-pre-receive\n');
      await Process.run('chmod', ['+x', hook.path]);

      final w = await start();
      final base = (await GitService.baseline(repo))!;
      File('${w.path}/lib/a.txt').writeAsStringSync('one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nTEN\n');
      expect((await GitService.changes(w)).single.path, 'lib/a.txt');
      expect((await GitService.diff(w)).single.path, 'lib/a.txt');
      expect((await GitService.uncommittedDiff(w)).single.path, 'lib/a.txt');
      expect(await GitService.changes(base.diffView), isEmpty);
      expect(await GitService.isDirty(w), isTrue);
      final ref = await GitService.checkpoint(w, 1);
      File('${w.path}/lib/a.txt').writeAsStringSync('gone\n');
      await GitService.restoreCheckpoint(w, ref);
      expect(File('${w.path}/lib/a.txt').readAsStringSync(), endsWith('TEN\n'));
      expect(await GitService.commitAll(w, 'Shout ten\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n'), isTrue);
      expect(await _git(w.path, ['log', '-1', '--format=%B']), 'Shout ten');
      expect(await GitService.commitSubjects(w), ['Shout ten']);

      File('${w.path}/README.md').writeAsStringSync('# App\n\nMore.\n');
      final readme = (await GitService.uncommittedDiff(w)).single;
      await GitService.revertHunk(w, readme, 0);
      expect(File('${w.path}/README.md').readAsStringSync(), '# App\n');

      // The main checkout moved on: nothing merges there (the agent rebases in its worktree instead).
      File('$repo/lib/a.txt').writeAsStringSync('ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n');
      await safe(repo, ['commit', '-q', '-am', 'Shout one']);
      await expectLater(
        GitService.fastForwardMerge(w, (await GitService.mergeCandidate(w)).sha),
        throwsA(isA<BaseMoved>()),
      );
      expect(await safe(repo, ['status', '--porcelain', '--untracked-files=no']), isEmpty);
      expect(File('$repo/lib/a.txt').readAsStringSync(), startsWith('ONE\n'));

      File('${w.path}/lib/b.txt').writeAsStringSync('bee\n');
      expect(await GitService.commitOnNewBranch(w, 'everyai/bee', 'Bee'), isNotNull);
      // A remote that is a folder here would run its own hooks: refused, in plain words.
      await expectLater(
        GitService.push(w),
        throwsA(predicate<GitError>((e) => e.message.contains('folder on this computer'))),
      );
      expect(await _git(remote, ['branch', '--list']), isEmpty);

      final copy = (await GitService.forkCopy(repo, worktreesDir: '${tmp.path}/forks', slug: 'f'))!;
      File('${copy.path}/lib/c.txt').writeAsStringSync('sea\n');
      expect((await GitService.mergeFork(copy, slug: 'f')).merged, ['lib/c.txt']);
      await GitService.removeWorktree(w, hooksDir: hooks);

      expect(File(marks).existsSync() ? File(marks).readAsStringSync() : '', isEmpty);
      // The trap works: plain git in the same repository runs it.
      await Process.run('git', ['-C', repo, 'status']);
      expect(File(marks).readAsStringSync(), contains('fsmonitor'));
    });

    test('the user\'s own hooks folder still runs on EveryAI\'s commits; the repository\'s does not', () async {
      final run = await arm();
      final mine = Directory('${tmp.path}/my-hooks')..createSync();
      final hook = File('${mine.path}/pre-commit')..writeAsStringSync('#!/bin/sh\n"$run" my-pre-commit\n');
      await Process.run('chmod', ['+x', hook.path]);
      final global = File('${tmp.path}/gitconfig')
        ..writeAsStringSync('[user]\n\tname = Dev\n\temail = dev@example.com\n[core]\n\thooksPath = ${mine.path}\n');
      final env = {'GIT_CONFIG_GLOBAL': global.path};
      File('$repo/lib/a.txt').writeAsStringSync('changed\n');
      await runGit(repo, ['add', '-A'], env: env);
      final commit = await runGit(repo, ['commit', '-q', '-m', 'Mine'], env: env);
      expect(commit.exitCode, 0, reason: '${commit.stderr}');
      expect(File(marks).readAsStringSync().trim().split('\n'), ['my-pre-commit']);
    });
  });
}
