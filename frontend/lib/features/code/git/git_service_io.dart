import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'git_models.dart';
import 'git_service.dart' show GitError;

Future<ProcessResult> _git(String dir, List<String> args, {Map<String, String>? env, bool check = true}) async {
  final res = await Process.run('git', ['-C', dir, ...args], environment: env);
  if (check && res.exitCode != 0) {
    final err = '${res.stderr}'.trim();
    throw GitError('git ${args.first}: ${err.isEmpty ? '${res.stdout}'.trim() : err}');
  }
  return res;
}

Future<String> _out(String dir, List<String> args, {Map<String, String>? env}) async =>
    '${(await _git(dir, args, env: env)).stdout}'.trim();

Future<String> dataDir() async => (await getApplicationSupportDirectory()).path;

Future<String?> repoRoot(String dir) async {
  try {
    final res = await _git(dir, ['rev-parse', '--show-toplevel'], check: false);
    return res.exitCode == 0 ? '${res.stdout}'.trim() : null;
  } on ProcessException {
    return null;
  }
}

Future<SessionWorktree> createWorktree({
  required String repoRoot,
  required String slug,
  required String worktreesDir,
  required String hooksDir,
}) async {
  final baseBranch = await _out(repoRoot, ['branch', '--show-current']);
  final baseCommit = await _out(repoRoot, ['rev-parse', 'HEAD']);
  final path = '$worktreesDir/$slug';
  final branch = 'everyai/$slug';
  await Directory(worktreesDir).create(recursive: true);
  await _git(repoRoot, ['worktree', 'add', '-q', '-b', branch, path, baseCommit]);
  final w = SessionWorktree(
    repoRoot: repoRoot,
    path: path,
    branch: branch,
    baseBranch: baseBranch,
    baseCommit: baseCommit,
  );
  await _installHooks(w, hooksDir);
  return w;
}

/// Points the worktree at EveryAI's hooks: commit-msg strips AI-credit
/// lines; every hook then runs the repository's own one.
Future<void> _installHooks(SessionWorktree w, String hooksDir) async {
  final configured = await _git(w.repoRoot, ['config', '--get', 'core.hooksPath'], check: false);
  final common = await _out(w.repoRoot, ['rev-parse', '--path-format=absolute', '--git-common-dir']);
  final custom = '${configured.stdout}'.trim();
  // A relative hooksPath (husky) is relative to the checkout the hook runs in.
  final original = custom.isEmpty
      ? "'$common/hooks'"
      : custom.startsWith('/')
      ? "'$custom'"
      : '"\$(git rev-parse --show-toplevel)/$custom"';
  final dir = Directory('$hooksDir/${w.slug}');
  await dir.create(recursive: true);
  for (final name in _hookNames) {
    final strip = name == 'commit-msg'
        ? 'grep -Eiv \'$_brandingPattern\' "\$1" > "\$1.everyai"; mv "\$1.everyai" "\$1"\n'
        : '';
    final f = File('${dir.path}/$name');
    await f.writeAsString(
      '#!/bin/sh\n# EveryAI session hook${name == 'commit-msg' ? ': keeps AI credits out of commit messages' : ''}.\n'
      '$strip'
      'orig=$original/$name\n'
      '[ -x "\$orig" ] && exec "\$orig" "\$@"\n'
      'exit 0\n',
    );
    await Process.run('chmod', ['+x', f.path]);
  }
  await _git(w.repoRoot, ['config', 'extensions.worktreeConfig', 'true']);
  await _git(w.path, ['config', '--worktree', 'core.hooksPath', dir.path]);
}

/// The POSIX ERE twin of `brandingLine`.
const _brandingPattern =
    r'^[[:space:]]*(co-authored-by|signed-off-by)[[:space:]]*:.*(openhands|all-hands|claude|anthropic|everyai|openai|chatgpt|gpt-|copilot|cursor|gemini|codex|\[bot\])'
    r'|generated (with|by) .*(openhands|claude|everyai|copilot|chatgpt|codex|cursor|gemini)'
    '|🤖';

const _hookNames = [
  'applypatch-msg', 'pre-applypatch', 'post-applypatch', 'pre-commit', 'pre-merge-commit', 'prepare-commit-msg', //
  'commit-msg', 'post-commit', 'pre-rebase', 'post-checkout', 'post-merge', 'pre-push', 'post-rewrite',
  'reference-transaction', 'pre-auto-gc', 'push-to-checkout',
];

/// Runs [run] with a throwaway index holding the whole working tree
/// (untracked files included), so the user's staging area is untouched.
Future<T> _withSnapshot<T>(SessionWorktree w, Future<T> Function(Map<String, String> env) run) async {
  final tmp = await Directory.systemTemp.createTemp('everyai-index');
  final env = {'GIT_INDEX_FILE': '${tmp.path}/index'};
  try {
    await _git(w.path, ['read-tree', 'HEAD'], env: env);
    await _git(w.path, ['add', '-A'], env: env);
    return await run(env);
  } finally {
    await tmp.delete(recursive: true);
  }
}

Future<List<FileChange>> changes(SessionWorktree w) => _withSnapshot(w, (env) async {
  final status = await _out(w.path, ['diff', '--cached', '-M', '--name-status', w.baseCommit], env: env);
  final numstat = await _out(w.path, ['diff', '--cached', '-M', '--numstat', w.baseCommit], env: env);
  final counts = <String, (int, int)>{};
  for (final line in const LineSplitter().convert(numstat)) {
    final parts = line.split('\t');
    if (parts.length < 3) continue;
    counts[parts.last] = (int.tryParse(parts[0]) ?? 0, int.tryParse(parts[1]) ?? 0);
  }
  return [
    for (final line in const LineSplitter().convert(status))
      if (line.split('\t') case [final code, ..., final path])
        FileChange(
          path,
          switch (code[0]) {
            'A' => ChangeKind.added,
            'D' => ChangeKind.deleted,
            'R' => ChangeKind.renamed,
            _ => ChangeKind.modified,
          },
          added: counts[path]?.$1 ?? 0,
          removed: counts[path]?.$2 ?? 0,
        ),
  ];
});

Future<List<FileDiff>> diff(SessionWorktree w) => _withSnapshot(w, (env) async {
  final res = await _git(w.path, ['diff', '--cached', '-M', '--no-color', w.baseCommit], env: env);
  return parseUnifiedDiff('${res.stdout}');
});

Future<List<FileDiff>> uncommittedDiff(SessionWorktree w) => _withSnapshot(w, (env) async {
  final res = await _git(w.path, ['diff', '--cached', '-M', '--no-color', 'HEAD'], env: env);
  return parseUnifiedDiff('${res.stdout}');
});

Future<List<String>> commitSubjects(SessionWorktree w) async {
  final out = await _out(w.path, ['log', '--format=%s', '${w.baseCommit}..HEAD']);
  return [
    for (final l in const LineSplitter().convert(out))
      if (l.trim().isNotEmpty) l.trim(),
  ];
}

Future<String> remoteUrl(SessionWorktree w) async {
  final res = await _git(w.path, ['remote', 'get-url', 'origin'], check: false);
  return res.exitCode == 0 ? '${res.stdout}'.trim() : '';
}

Future<bool> ghReady(String dir) async {
  try {
    final res = await Process.run('gh', ['auth', 'status'], workingDirectory: dir);
    return res.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<void> revertHunk(SessionWorktree w, FileDiff file, int hunk) async {
  final p = await Process.start('git', ['-C', w.path, 'apply', '-R', '--whitespace=nowarn', '-']);
  p.stdin.write(file.patchFor(hunk));
  await p.stdin.close();
  final err = await p.stderr.transform(utf8.decoder).join();
  if (await p.exitCode != 0) throw GitError("Couldn't revert that change: ${err.trim()}");
}

Future<bool> commitAll(SessionWorktree w, String message) async {
  await _git(w.path, ['add', '-A']);
  final staged = await _git(w.path, ['diff', '--cached', '--quiet'], check: false);
  if (staged.exitCode == 0) return false;
  await _git(w.path, ['commit', '-q', '-m', message]);
  return true;
}

Future<String> checkpoint(SessionWorktree w, int turn) => _withSnapshot(w, (env) async {
  final tree = await _out(w.path, ['write-tree'], env: env);
  final sha = await _out(w.path, ['commit-tree', tree, '-p', 'HEAD', '-m', 'EveryAI checkpoint before turn $turn']);
  final ref = 'refs/everyai/${w.slug}/turn-$turn';
  await _git(w.path, ['update-ref', ref, sha]);
  return ref;
});

Future<void> restoreCheckpoint(SessionWorktree w, String ref) async {
  // Nothing is touched without a checkpoint to restore from: cleaning first
  // would delete untracked files and then have nothing to put back.
  try {
    await _git(w.path, ['rev-parse', '--verify', '--quiet', '$ref^{commit}']);
  } on Object {
    throw const GitError('There is no checkpoint for that turn, so the files were left as they are.');
  }
  // Untracked files the checkpoint has are restored from it below.
  await _git(w.path, ['clean', '-fdq']);
  await _git(w.path, ['restore', '--source=$ref', '--worktree', '--', ':/']);
}

Future<({int ahead, int behind})> aheadBehind(SessionWorktree w) async {
  final counts = await _out(w.path, ['rev-list', '--left-right', '--count', '${w.baseBranch}...HEAD']);
  final [behind, ahead] = counts.split(RegExp(r'\s+')).map(int.parse).toList();
  return (ahead: ahead, behind: behind);
}

Future<String> squashMerge(SessionWorktree w, String message) async {
  final dirty = await _out(w.repoRoot, ['status', '--porcelain', '--untracked-files=no']);
  if (dirty.isNotEmpty) {
    throw const GitError('Your main checkout has uncommitted changes. Commit or stash them, then merge again.');
  }
  final current = await _out(w.repoRoot, ['branch', '--show-current']);
  if (current != w.baseBranch) {
    throw GitError('Your main checkout is on $current. Switch it to ${w.baseBranch} to merge this session.');
  }
  await commitAll(w, message);
  await _git(w.repoRoot, ['merge', '--squash', '-q', w.branch]);
  final staged = await _git(w.repoRoot, ['diff', '--cached', '--quiet'], check: false);
  if (staged.exitCode == 0) throw const GitError('There is nothing to merge: the session made no changes.');
  await _git(w.repoRoot, ['commit', '-q', '-m', message]);
  return _out(w.repoRoot, ['rev-parse', 'HEAD']);
}

Future<void> push(SessionWorktree w) => _git(w.path, ['push', '-q', '-u', 'origin', w.branch]);

Future<String> createPr(SessionWorktree w, {required String title, required String body}) async {
  final ProcessResult res;
  try {
    res = await Process.run('gh', [
      'pr',
      'create',
      '--head',
      w.branch,
      '--base',
      w.baseBranch,
      '--title',
      title,
      '--body',
      body,
    ], workingDirectory: w.path);
  } on ProcessException {
    throw const GitError('Creating a pull request needs the GitHub CLI: install gh and run `gh auth login`.');
  }
  if (res.exitCode != 0) throw GitError("Couldn't create the pull request: ${'${res.stderr}'.trim()}");
  return '${res.stdout}'.trim().split('\n').last;
}

Future<void> removeWorktree(SessionWorktree w, {required String hooksDir, bool deleteBranch = true}) async {
  await _git(w.repoRoot, ['worktree', 'remove', '--force', w.path], check: false);
  await _git(w.repoRoot, ['worktree', 'prune'], check: false);
  if (deleteBranch) await _git(w.repoRoot, ['branch', '-q', '-D', w.branch], check: false);
  final refs = await _git(w.repoRoot, ['for-each-ref', '--format=%(refname)', 'refs/everyai/${w.slug}/'], check: false);
  for (final ref in const LineSplitter().convert('${refs.stdout}')) {
    if (ref.isNotEmpty) await _git(w.repoRoot, ['update-ref', '-d', ref], check: false);
  }
  final hooks = Directory('$hooksDir/${w.slug}');
  if (hooks.existsSync()) await hooks.delete(recursive: true);
}
