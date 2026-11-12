import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/process/supervisor.dart';
import '../drivers/short_run.dart';
import 'git_env.dart';
import 'git_guard.dart';
import 'git_models.dart';
import 'git_service.dart' show BaseMoved, GitError;

export 'repo_check_io.dart' show checkRepo;

/// Subcommands that only read (with [guardFlags] on), so they skip the config read. Anything that writes a ref
/// or the index can fire a hook set in config (`hook.<name>.command`), which only [repoGuard] turns off.
const _plain = {'rev-parse', 'check-ref-format', 'show-ref', 'for-each-ref', 'rev-list', 'log', 'check-ignore'};

/// Where git for [dir] runs: inside its environment (a WSL distro's own files, see [gitRunsInside]), or null for
/// this computer.
Future<GitInside?> _insideFor(String dir) async {
  final inside = await gitInsideOf?.call(dir);
  return inside != null && gitRunsInside(inside.env, dir) ? inside : null;
}

/// The null device as the git for [dir] names it.
Future<String> _devNull(String dir) async => Platform.isWindows && await _insideFor(dir) == null ? 'NUL' : '/dev/null';

/// The one place EveryAI starts git (and the few programs next to it) for [dir] (`-C`'s, unless given): on this
/// computer, or for a folder inside an environment through its bridge, with the host paths among [args] and [env]'s
/// values (`GIT_INDEX_FILE`) as it sees them.
///
/// Through the supervisor, bounded ([gitTimeout]): a git that hangs (a credential prompt, a lock, a dead network) is
/// stopped, verified, with what it started, and the call throws a [GitError] saying so. A git that can't start throws
/// a [ProcessException], as before. [stdin] is written to it; [stdoutEncoding] null gives stdout as bytes.
Future<ProcessResult> _proc(
  List<String> args, {
  String exe = 'git',
  String? dir,
  Map<String, String>? env,
  Encoding? stdoutEncoding = systemEncoding,
  String? stdin,
}) async {
  final cmd = await _command(exe, args, dir: dir, env: env);
  final r = await runShort(
    cmd.exe,
    cmd.args,
    timeout: exe == 'git' ? gitTimeout(args) : const Duration(minutes: 1),
    env: cmd.env ?? const {},
    owner: const ProbeOwner('git'),
    stdin: stdin,
    encoding: stdoutEncoding ?? systemEncoding,
    stderrEncoding: systemEncoding,
    label: '$exe ${gitSubcommand(args) ?? ''}'.trim(),
  );
  return _result(
    exe == 'git' ? 'git ${gitSubcommand(args) ?? ''}'.trim() : exe,
    exe,
    args,
    r,
    bytes: stdoutEncoding == null,
  );
}

/// [r] as `Process.run` gave it; a run that was stopped (time out, cancel) throws a [GitError], one that couldn't
/// start a [ProcessException] (callers read that as "not installed").
ProcessResult _result(String what, String exe, List<String> args, RunResult r, {bool bytes = false}) {
  switch (r) {
    case Finished(:final code):
      return ProcessResult(0, code, bytes ? r.stdoutBytes : r.stdout, r.stderr);
    case TimedOut(:final kill) || Cancelled(:final kill):
      logStop(what, kill);
      throw GitError(runProblem(what, r)!);
    case StartFailed(:final error) || Refused(reason: final error):
      throw ProcessException(exe, args, error);
  }
}

/// The git subcommand in [args] (past `-C dir`, `-c k=v` and other options before it), or null.
String? gitSubcommand(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (const {'-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path'}.contains(a)) {
      i++;
      continue;
    }
    if (a.startsWith('-')) continue;
    return a;
  }
  return null;
}

/// How long a git call may run before it is stopped: what talks to a remote or checks out a whole tree (a worktree
/// of a big repository, a checkout, a merge) 10 minutes, what walks or writes the working tree 3, the rest (refs,
/// config, rev-parse) 1.
Duration gitTimeout(List<String> args) => switch (gitSubcommand(args)) {
  'fetch' ||
  'pull' ||
  'push' ||
  'clone' ||
  'ls-remote' ||
  'submodule' ||
  'lfs' ||
  'worktree' ||
  'checkout' ||
  'read-tree' ||
  'merge' => const Duration(minutes: 10),
  'add' ||
  'diff' ||
  'show' ||
  'status' ||
  'clean' ||
  'restore' ||
  'write-tree' ||
  'apply' ||
  'merge-tree' ||
  'merge-file' ||
  'rebase' ||
  'switch' ||
  'commit' ||
  'commit-tree' ||
  'log' ||
  'stash' ||
  'reset' ||
  'check-ignore' ||
  'init' => const Duration(minutes: 3),
  _ => const Duration(minutes: 1),
};

/// How long a `gh` call may run (it talks to GitHub).
const ghTimeout = Duration(minutes: 3);

/// `gh` [args] in [dir], bounded ([ghTimeout]); see [_result].
Future<ProcessResult> _gh(List<String> args, {String? dir, Map<String, String>? env}) async {
  final r = await runShort(
    'gh',
    args,
    timeout: ghTimeout,
    cwd: dir,
    env: env ?? const {},
    owner: const ProbeOwner('gh'),
    encoding: systemEncoding,
    label: 'gh ${args.take(2).join(' ')}',
  );
  return _result('gh ${args.take(2).join(' ')}', 'gh', args, r);
}

/// Runs guarded git [args] in [dir] with [input] on stdin; throws a [GitError] when it fails.
Future<String> _piped(String dir, List<String> args, String input, {Map<String, String>? env}) async {
  final res = await _proc(
    await guardedArgs(dir, args, env: env),
    env: env,
    stdin: input,
    stdoutEncoding: utf8,
  );
  if (res.exitCode != 0) throw GitError('git ${args.first}: ${'${res.stderr}'.trim()}');
  return '${res.stdout}';
}

/// What [_proc] starts for [exe] [args] (tests).
@visibleForTesting
Future<({String exe, List<String> args, Map<String, String>? env})> gitCommand(
  String exe,
  List<String> args, {
  String? dir,
  Map<String, String>? env,
}) => _command(exe, args, dir: dir, env: env);

Future<({String exe, List<String> args, Map<String, String>? env})> _command(
  String exe,
  List<String> args, {
  String? dir,
  Map<String, String>? env,
}) async {
  final at = dir ?? (args.length > 1 && args.first == '-C' ? args[1] : null);
  final inside = at == null ? null : await _insideFor(at);
  if (inside == null) return (exe: exe, args: args, env: env);
  final e = inside.env;
  // Only git's own variables (GIT_INDEX_FILE, GIT_CONFIG_*) go inside: a caller's env may be the app's whole
  // environment (guardedEnv), whose Windows names (`ProgramFiles(x86)`) no bridge can carry and whose values
  // (keys among them) don't belong in the distro.
  final w = e.wrap(
    exe,
    [for (final a in args) envArg(e, a)],
    env: {
      for (final v in (env ?? const {}).entries)
        if (v.key.startsWith('GIT_')) v.key: envArg(e, v.value),
    },
  );
  return (exe: w.executable, args: w.args, env: w.environment);
}

/// The repository's guard for [dir]: [guardFlags] plus [repoGuard]'s overrides, its refusal and its block.
Future<({List<String> fixed, List<String> args, List<GitSetting> config, String? refusal, String? block})> _guard(
  String dir, {
  Map<String, String>? env,
}) async {
  final fixed = guardFlags(await _devNull(dir));
  final res = await _proc(['-C', dir, ...fixed, 'config', '--list', '--show-scope', '-z'], env: env);
  if (res.exitCode != 0) {
    final err = '${res.stderr}'.trim();
    // --show-scope came in git 2.26; without it the repository's config can't be told from the user's.
    if (err.contains('show-scope')) throw const GitError('EveryAI needs git 2.26 or later: update git and try again.');
    throw GitError('git config: $err');
  }
  final guard = repoGuard(parseConfigList('${res.stdout}'));
  return (
    fixed: fixed,
    args: [...fixed, ...guard.args],
    config: guard.config,
    refusal: guard.refusal,
    block: guard.block,
  );
}

/// The full argument list for an EveryAI git call in [dir]: [guardFlags], the overrides for programs the
/// repository's own config names ([repoGuard]), then [args], diffs with [diffFlags]. Throws [GitError] when the
/// call would store files the repository's config can't be guarded for.
Future<List<String>> guardedArgs(String dir, List<String> args, {Map<String, String>? env}) async {
  final cmd = args.isEmpty ? '' : args.first;
  final call = [
    if (cmd == 'diff' || cmd == 'show') ...[cmd, ...diffFlags, ...args.skip(1)] else ...args,
  ];
  if (_plain.contains(cmd)) return ['-C', dir, ...guardFlags(await _devNull(dir)), ...call];
  final guard = await _guard(dir, env: env);
  if (guard.block case final why?) throw GitError(why);
  if (guard.refusal case final why? when storesFiles(cmd)) throw GitError(why);
  return ['-C', dir, ...guard.args, ...call];
}

/// Runs git in [dir] the way EveryAI's own calls do: nothing the repository defines runs (see `git_guard.dart`).
Future<ProcessResult> runGit(String dir, List<String> args, {Map<String, String>? env}) async =>
    _proc(await guardedArgs(dir, args, env: env), env: env);

/// [base] (the app's environment when null) plus the guard as `GIT_CONFIG_*` variables, for a program that runs
/// git itself in [dir] (a shell, gh). Diffs it runs still need [diffFlags]. Never throws: without a readable
/// config only [guardFlags] are in it.
Future<Map<String, String>> guardedEnv(String dir, {Map<String, String>? base}) async {
  final env = base ?? Platform.environment;
  final count = int.tryParse(env['GIT_CONFIG_COUNT'] ?? '') ?? 0;
  try {
    final guard = await _guard(dir, env: env);
    // The flags as before; the repository's overrides as pairs, so a key with '=' in it still reaches git.
    final fixed = configEnv(guard.fixed, count: count);
    return {...env, ...fixed, ...configEnvOf(guard.config, count: int.parse(fixed['GIT_CONFIG_COUNT']!))};
  } on Object {
    return {...env, ...configEnv(guardFlags(Platform.isWindows ? 'NUL' : '/dev/null'), count: count)};
  }
}

Future<ProcessResult> _git(String dir, List<String> args, {Map<String, String>? env, bool check = true}) async {
  final res = await runGit(dir, args, env: env);
  if (check && res.exitCode != 0) {
    final err = '${res.stderr}'.trim();
    throw GitError('git ${args.first}: ${err.isEmpty ? '${res.stdout}'.trim() : err}');
  }
  return res;
}

Future<String> _out(String dir, List<String> args, {Map<String, String>? env}) async =>
    '${(await _git(dir, args, env: env)).stdout}'.trim();

Future<String> dataDir() async => (await getApplicationSupportDirectory()).path;

Future<List<String>> worktrees(String dir) async {
  try {
    final res = await _git(dir, ['worktree', 'list', '--porcelain'], check: false);
    if (res.exitCode != 0) return const [];
    final paths = worktreePaths('${res.stdout}');
    final inside = await _insideFor(dir);
    return inside == null ? paths : [for (final p in paths) hostLike(inside.env.toHostPath(p) ?? p, dir)];
  } on Object {
    return const [];
  }
}

/// The paths in `git worktree list --porcelain` output (prunable and bare entries left out).
List<String> worktreePaths(String porcelain) {
  final out = <String>[];
  for (final block in porcelain.split(RegExp(r'\n\s*\n'))) {
    final lines = block.split('\n');
    final path = lines.firstWhere((l) => l.startsWith('worktree '), orElse: () => '');
    if (path.isEmpty || lines.any((l) => l == 'bare' || l.startsWith('prunable'))) continue;
    out.add(path.substring('worktree '.length).trim());
  }
  return out;
}

Future<String?> repoRoot(String dir) async {
  try {
    final res = await _git(dir, ['rev-parse', '--show-toplevel'], check: false);
    if (res.exitCode != 0) return null;
    final root = '${res.stdout}'.trim();
    // A dotfiles repo at the home folder or above isn't the project's: snapshots
    // and worktrees of it would copy the whole home folder.
    if (await _insideFor(dir) case final inside?) {
      if (root == '/' || RegExp(r'^/(?:root|home/[^/]+)/?$').hasMatch(root)) return null;
      final host = inside.env.toHostPath(root);
      return host == null ? null : hostLike(host, dir);
    }
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty && (home == root || home.startsWith('$root/'))) return null;
    return root;
  } on ProcessException {
    return null;
  }
}

Future<bool> hasCommits(String repoRoot) async {
  try {
    return (await _git(repoRoot, ['rev-parse', '--verify', '--quiet', 'HEAD^{commit}'], check: false)).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// `git worktree add -q [args]` making [path] (and [branch] when given). When it fails (stopped by its time limit or
/// a cancel, or refused) and left a half-made worktree at a [path] that wasn't there before, that worktree goes
/// again (and [branch], when this call made it), best effort and logged, so a retry doesn't hit "already exists".
Future<void> _worktreeAdd(String repo, String path, List<String> args, {String? branch}) async {
  final pathWasFree = FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound;
  final branchWasFree =
      branch != null &&
      (await _git(repo, ['rev-parse', '--verify', '--quiet', 'refs/heads/$branch'], check: false)).exitCode != 0;
  try {
    await _git(repo, ['worktree', 'add', '-q', ...args]);
  } on Object catch (e) {
    if (!pathWasFree) rethrow;
    debugPrint('git worktree add $path failed ($e); removing what it left.');
    try {
      final removed = await _git(repo, ['worktree', 'remove', '--force', path], check: false);
      if (removed.exitCode != 0 && Directory(path).existsSync()) await Directory(path).delete(recursive: true);
      await _git(repo, ['worktree', 'prune'], check: false);
      if (branchWasFree) await _git(repo, ['branch', '-D', branch], check: false);
    } on Object catch (c) {
      debugPrint('git worktree add $path: the half-made worktree could not be removed ($c).');
    }
    rethrow;
  }
}

Future<SessionWorktree> createWorktree({
  required String repoRoot,
  required String slug,
  required String worktreesDir,
  required String hooksDir,
  String? from,
}) async {
  final baseBranch = await _out(repoRoot, ['branch', '--show-current']);
  final baseCommit = from ?? await _out(repoRoot, ['rev-parse', 'HEAD']);
  final path = '$worktreesDir/$slug';
  final branch = 'everyai/$slug';
  await Directory(worktreesDir).create(recursive: true);
  await _worktreeAdd(repoRoot, path, ['-b', branch, path, baseCommit], branch: branch);
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
/// lines; every hook then runs the repository's own one. They are for the
/// agent's own git commands: EveryAI's calls run no hooks (`git_guard.dart`).
Future<void> _installHooks(SessionWorktree w, String hooksDir) async {
  // Without guardFlags, whose hooksPath would come back (`git config` runs nothing).
  final configured = await _proc(['-C', w.repoRoot, 'config', '--get', 'core.hooksPath']);
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
    await _proc(['+x', f.path], exe: 'chmod', dir: w.repoRoot);
  }
  await _git(w.repoRoot, ['config', 'extensions.worktreeConfig', 'true']);
  await _git(w.path, ['config', '--worktree', 'core.hooksPath', dir.path]);
}

/// The POSIX ERE twin of `brandingLine`.
const _brandingPattern =
    r'^[[:space:]]*(co-authored-by|signed-off-by|assisted-by)[[:space:]]*:.*(openhands|all-hands|claude|anthropic|everyai|openai|chatgpt|gpt-|copilot|cursor|gemini|codex|opencode|\[bot\])'
    r'|generated (with|by) .*(openhands|claude|everyai|copilot|chatgpt|codex|cursor|gemini|opencode)'
    r'|^[[:space:]]*claude-session[[:space:]]*:|claude\.ai/code/session'
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
    // A repository with no commit yet starts from nothing.
    final head = await _git(w.path, ['rev-parse', '--verify', '-q', 'HEAD'], check: false);
    await _git(w.path, head.exitCode == 0 ? ['read-tree', 'HEAD'] : ['read-tree', '--empty'], env: env);
    await _git(w.path, ['add', '-A'], env: env);
    return await run(env);
  } finally {
    await tmp.delete(recursive: true);
  }
}

Future<GitBaseline?> baseline(String dir) async {
  final root = await repoRoot(dir);
  if (root == null) return null;
  // No commit yet (a fresh `git init`): everything the session makes is new.
  final commit = await hasCommits(root) ? (await _out(root, ['rev-parse', 'HEAD'])).trim() : _emptyTree;
  final branch = (await _git(root, ['symbolic-ref', '--short', '-q', 'HEAD'], check: false)).stdout.toString().trim();
  final view = SessionWorktree(repoRoot: root, path: dir, branch: branch, baseBranch: branch, baseCommit: commit);
  final tree = await _withSnapshot(view, (env) async => (await _out(dir, ['write-tree'], env: env)).trim());
  return GitBaseline(repoRoot: root, dir: dir, branch: branch, commit: commit, tree: tree);
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

/// What a fork changed in its own worktree since its base, uncommitted work included; the dependency folders it
/// borrows from its parent are left out.
Future<List<FileDiff>> forkDiff(ForkCopy copy) async {
  final tmp = await Directory.systemTemp.createTemp('everyai-index');
  final env = {'GIT_INDEX_FILE': '${tmp.path}/index'};
  try {
    await _git(copy.root, ['read-tree', 'HEAD'], env: env);
    await _git(copy.root, ['add', '-A', '--', '.', for (final l in copy.links) ':(exclude)$l'], env: env);
    final res = await _git(copy.root, ['diff', '--cached', '-M', '--no-color', copy.base], env: env);
    return parseUnifiedDiff('${res.stdout}');
  } finally {
    await tmp.delete(recursive: true);
  }
}

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

Future<bool> isDirty(SessionWorktree w) async => (await _out(w.path, ['status', '--porcelain'])).isNotEmpty;

Future<String> headCommit(SessionWorktree w) => _out(w.path, ['rev-parse', 'HEAD']);

Future<BranchPr?> prFor(SessionWorktree w) async {
  try {
    final res = await _gh(
      ['pr', 'view', w.branch, '--json', 'number,url,state,headRefOid'],
      dir: w.path,
      env: await guardedEnv(w.path),
    );
    // Non-zero: no pull request for the branch, no remote, or gh isn't signed in.
    return res.exitCode == 0 ? parsePrView('${res.stdout}') : null;
  } on ProcessException {
    return null;
  }
}

Future<PrStatus?> prStatus(String dir, String target) async {
  if (target.isEmpty || target.startsWith('-')) return null;
  if (!Directory(dir).existsSync()) throw GitError("The session's folder is gone: $dir");
  final ProcessResult res;
  try {
    res = await _gh(['pr', 'view', target, '--json', prStatusFields], dir: dir, env: await guardedEnv(dir));
  } on ProcessException catch (e) {
    throw GitError("Couldn't run gh: ${e.message}");
  }
  if (res.exitCode == 0) {
    return parsePrStatus('${res.stdout}') ?? (throw const GitError("gh's answer couldn't be read."));
  }
  // No pull request is an answer; a network, rate-limit or sign-in failure is not.
  final err = '${res.stderr}';
  if (ghSaysNoPr(err)) return null;
  throw GitError("Couldn't ask GitHub: ${err.trim()}");
}

Future<PrMergeMethod> prMergeMethod(String dir, PrStatus pr) async {
  try {
    final repo = await _gh(
      [
        'repo',
        'view',
        if (pr.repo.isNotEmpty) pr.repo,
        '--json',
        'mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed',
      ],
      dir: Directory(dir).existsSync() ? dir : null,
      env: await guardedEnv(dir),
    );
    return prMergeMethodOf(repo.exitCode == 0 ? '${repo.stdout}' : '');
  } on ProcessException {
    return PrMergeMethod.squash;
  } on GitError catch (e) {
    // gh didn't answer in time (stopped): squash, the default, as when it can't be asked.
    debugPrint('EveryAI git: ${e.message}; merging with squash.');
    return PrMergeMethod.squash;
  }
}

Future<String?> prMergeBlocker(String dir, PrStatus pr) async {
  if (!Directory(dir).existsSync()) return "The session's folder is gone, so what it holds can't be checked.";
  try {
    if (await _out(dir, ['status', '--porcelain']) case final dirty when dirty.isNotEmpty) {
      return "The session has changes that aren't committed and pushed. Commit and push them first.";
    }
    final head = await _out(dir, ['rev-parse', 'HEAD']);
    if (pr.head.isNotEmpty && head != pr.head) {
      return "The session isn't at the pull request's latest commit (it has commits that aren't pushed, or GitHub "
          'has newer ones). Push or pull first.';
    }
  } on Object catch (e) {
    return "Couldn't check the session's folder: $e";
  }
  return null;
}

Future<void> mergePr(String dir, PrStatus pr, PrMergeMethod method) async {
  if (!Directory(dir).existsSync()) throw GitError("The session's folder is gone: $dir");
  final ProcessResult res;
  try {
    res = await _gh(
      [
        'pr',
        'merge',
        '${pr.number}',
        method.flag,
        // Only the commit the user saw: GitHub refuses when the branch moved since.
        if (pr.head.isNotEmpty) ...['--match-head-commit', pr.head],
        if (pr.repo.isNotEmpty) ...['--repo', pr.repo],
      ],
      dir: dir,
      env: await guardedEnv(dir),
    );
  } on ProcessException {
    throw const GitError('Merging needs the GitHub CLI: install gh and run `gh auth login`.');
  }
  if (res.exitCode != 0) throw GitError("Couldn't merge #${pr.number}: ${'${res.stderr}'.trim()}");
}

Future<bool> ghReady(String dir) async {
  try {
    final res = await _gh(['auth', 'status', '--hostname', 'github.com'], dir: dir);
    return res.exitCode == 0;
  } on ProcessException {
    return false;
  } on GitError catch (e) {
    debugPrint('EveryAI git: ${e.message}; counted as not signed in.');
    return false;
  }
}

Future<Set<String>> ignoredAmong(String dir, List<String> paths) async {
  if (paths.isEmpty) return const {};
  try {
    final res = await _proc(
      await guardedArgs(dir, ['check-ignore', '--stdin', '-z']),
      stdin: '${paths.join('\x00')}\x00',
      stdoutEncoding: utf8,
    );
    // 1: none ignored; 128: not a repository.
    if (res.exitCode != 0) return const {};
    return {
      for (final path in '${res.stdout}'.split('\x00'))
        if (path.isNotEmpty) path,
    };
  } on Object catch (e) {
    // Shown as not ignored; the log says why.
    debugPrint('EveryAI git: check-ignore in $dir failed: $e');
    return const {};
  }
}

Future<void> revertHunk(SessionWorktree w, FileDiff file, int hunk) async {
  final res = await _proc(
    await guardedArgs(w.path, ['apply', '-R', '--whitespace=nowarn', '-']),
    stdin: file.patchFor(hunk),
    stdoutEncoding: utf8,
  );
  if (res.exitCode != 0) throw GitError("Couldn't revert that change: ${'${res.stderr}'.trim()}");
}

/// Stages [paths] (everything when null).
Future<void> _stage(SessionWorktree w, List<String>? paths) => _git(w.path, [
  'add',
  '-A',
  if (paths != null) ...['--', ...paths],
]);

Future<bool> _hasStaged(SessionWorktree w) async =>
    (await _git(w.path, ['diff', '--cached', '--quiet'], check: false)).exitCode != 0;

/// Commits [paths] (everything when null); false when there was nothing to commit.
Future<bool> commitAll(SessionWorktree w, String message, {List<String>? paths}) async {
  await _stage(w, paths);
  if (!await _hasStaged(w)) return false;
  // EveryAI's own commits skip the hooks, the session's commit-msg one too: its job is done here.
  await _git(w.path, [
    'commit',
    '-q',
    '-m',
    stripBranding(message),
    if (paths != null) ...['--', ...paths],
  ]);
  return true;
}

/// Switches to new branch [branch] (the changes come along) and commits [paths] there (everything when null);
/// returns the commit, or null when there was nothing to commit. A name git refuses, a branch that exists, an
/// empty commit and a failed commit all leave the checkout on the branch it was on, with no new branch.
Future<String?> commitOnNewBranch(SessionWorktree w, String branch, String message, {List<String>? paths}) async {
  final name = branch.trim();
  if ((await _git(w.path, ['check-ref-format', '--branch', name], check: false)).exitCode != 0 ||
      name.startsWith('-')) {
    throw GitError('"$name" is not a branch name git accepts.');
  }
  if ((await _git(w.path, ['show-ref', '--verify', '--quiet', 'refs/heads/$name'], check: false)).exitCode == 0) {
    throw GitError('There is a branch called $name already.');
  }
  await _stage(w, paths);
  if (!await _hasStaged(w)) return null;
  final before = await _out(w.path, ['branch', '--show-current']);
  await _git(w.path, ['switch', '-q', '-c', name]);
  try {
    await _git(w.path, [
      'commit',
      '-q',
      '-m',
      stripBranding(message),
      if (paths != null) ...['--', ...paths],
    ]);
  } on Object {
    // Back where it was, the new branch gone, so the same try can run again.
    await _git(w.path, before.isEmpty ? ['switch', '-q', '--detach', '-'] : ['switch', '-q', before], check: false);
    await _git(w.path, ['branch', '-q', '-D', name], check: false);
    rethrow;
  }
  return headCommit(w);
}

/// The tree of everything in the folder right now (untracked files too, ignored ones not).
Future<String> snapshotTree(SessionWorktree w) =>
    _withSnapshot(w, (env) async => (await _out(w.path, ['write-tree'], env: env)).trim());

/// The paths whose content differs between snapshot [tree] and the folder now.
Future<List<String>> changedSince(SessionWorktree w, String tree) => _withSnapshot(w, (env) async {
  final out = await _out(w.path, ['diff', '--cached', '--name-only', '--no-renames', '-z', tree], env: env);
  return [
    for (final p in out.split('\x00'))
      if (p.isNotEmpty) p,
  ];
});

/// The paths whose content differs between trees (or commits) [from] and [to].
Future<List<String>> changedBetween(SessionWorktree w, String from, String to) async {
  final out = await _out(w.path, ['diff', '--name-only', '--no-renames', '-z', from, to]);
  return [
    for (final p in out.split('\x00'))
      if (p.isNotEmpty) p,
  ];
}

/// Whether any of [paths] has changes not committed.
Future<bool> isDirtyAmong(SessionWorktree w, List<String> paths) async =>
    paths.isNotEmpty && (await _out(w.path, ['status', '--porcelain', '--', ...paths])).isNotEmpty;

Future<String> checkpoint(SessionWorktree w, int turn) => _withSnapshot(w, (env) async {
  final tree = await _out(w.path, ['write-tree'], env: env);
  final sha = await _out(w.path, ['commit-tree', tree, '-p', 'HEAD', '-m', 'EveryAI checkpoint before turn $turn']);
  final ref = 'refs/everyai/${w.slug}/turn-$turn';
  await _git(w.path, ['update-ref', ref, sha]);
  return ref;
});

/// A commit of everything in [w]'s folder now (uncommitted and untracked work too, ignored files not), on top of its
/// HEAD, kept under `refs/everyai/<slug>/handoff` so it isn't collected. A task that waits on this one starts from it.
/// [w]'s own branch, index and files are left as they are.
Future<String> handoffCommit(SessionWorktree w) => _withSnapshot(w, (env) async {
  final tree = await _out(w.path, ['write-tree'], env: env);
  final sha = await _out(w.path, ['commit-tree', tree, '-p', 'HEAD', '-m', 'EveryAI: work of ${w.slug}, handed on']);
  await _git(w.path, ['update-ref', 'refs/everyai/${w.slug}/handoff', sha]);
  return sha;
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

/// Fast-forwards the base branch in the main checkout to [sha], the commit the user confirmed, which must be one
/// commit on top of it. Returns the merged commit. Nothing merges when the base moved (not a fast forward):
/// [BaseMoved]; any other failure is a [GitError] with git's own words.
Future<String> fastForwardMerge(SessionWorktree w, String sha) async {
  final dirty = await _out(w.repoRoot, ['status', '--porcelain', '--untracked-files=no']);
  if (dirty.isNotEmpty) {
    throw const GitError('Your main checkout has uncommitted changes. Commit or stash them, then merge again.');
  }
  final current = await _out(w.repoRoot, ['branch', '--show-current']);
  if (current != w.baseBranch) {
    throw GitError('Your main checkout is on $current. Switch it to ${w.baseBranch} to merge this session.');
  }
  final onTop = await _git(w.repoRoot, ['merge-base', '--is-ancestor', w.baseBranch, sha], check: false);
  if (onTop.exitCode != 0) throw const BaseMoved();
  if (await _out(w.repoRoot, ['rev-list', '--count', '${w.baseBranch}..$sha']) != '1') {
    throw GitError('The commit to merge is no longer one commit on top of ${w.baseBranch}. Press Merge again.');
  }
  final res = await _git(w.repoRoot, ['merge', '--ff-only', '-q', sha], check: false);
  if (res.exitCode != 0) {
    final why = '${res.stderr}'.trim();
    throw GitError(why.isEmpty ? "git couldn't fast-forward ${w.baseBranch}." : why);
  }
  return _out(w.repoRoot, ['rev-parse', 'HEAD']);
}

/// The session worktree's newest commit and its subject: what Merge would put on the base.
Future<({String sha, String subject})> mergeCandidate(SessionWorktree w) async {
  final out = await _out(w.path, ['log', '-1', '--format=%H%n%s']);
  final [sha, ...subject] = out.split('\n');
  return (sha: sha, subject: subject.join('\n'));
}

/// Pushes the session branch. Not to a folder on this computer: git runs that repository's own hooks (and a
/// `receivepack` the repository sets) here, with none of EveryAI's flags.
Future<void> push(SessionWorktree w) async {
  final res = await _git(w.path, [
    '-c',
    'protocol.file.allow=never',
    'push',
    '-q',
    '-u',
    'origin',
    w.branch,
  ], check: false);
  if (res.exitCode == 0) return;
  final err = '${res.stderr}'.trim();
  if (err.contains("transport 'file' not allowed")) {
    throw const GitError(
      'EveryAI doesn\'t push to a folder on this computer, since the repository there can run its own hooks. '
      'Push from a terminal instead.',
    );
  }
  throw GitError('git push: $err');
}

Future<String> createPr(SessionWorktree w, {required String title, required String body}) async {
  final ProcessResult res;
  try {
    res = await _gh(
      [
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
        // gh runs git itself (status, remotes): the same guard reaches it through the environment.
      ],
      dir: w.path,
      env: await guardedEnv(w.path),
    );
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

// ------------------------------------------------------------------ forks

/// Dependency folders a fork borrows from its parent instead of reinstalling.
const _borrowed = ['node_modules', '.venv', 'venv'];

Future<ForkCopy?> forkCopy(String dir, {required String worktreesDir, required String slug}) async {
  final root = await repoRoot(dir);
  if (root == null) return null;
  // A fresh `git init` with no commit yet still gets a fork: its base has no parent.
  final head = await hasCommits(root) ? (await _out(root, ['rev-parse', 'HEAD'])).trim() : null;
  final view = SessionWorktree(repoRoot: root, path: dir, branch: '', baseBranch: '', baseCommit: head ?? _emptyTree);
  final tree = await _withSnapshot(view, (env) async => (await _out(dir, ['write-tree'], env: env)).trim());
  final base = (await _out(root, [
    '-c', 'user.name=EveryAI', '-c', 'user.email=agent@everyai.invalid', //
    'commit-tree', tree, if (head != null) ...['-p', head], '-m', 'EveryAI fork base',
  ])).trim();
  final wt = '$worktreesDir/$slug';
  await Directory(worktreesDir).create(recursive: true);
  await _worktreeAdd(root, wt, ['--detach', wt, base]);
  // Asked of git: [dir] may reach the repository through a symlink.
  var rel = (await _out(dir, ['rev-parse', '--show-prefix'])).trim();
  if (rel.endsWith('/')) rel = rel.substring(0, rel.length - 1);
  final path = rel.isEmpty ? wt : '$wt/$rel';
  final links = <String>[];
  for (final (from, to, prefix) in [(dir, path, rel), if (rel.isNotEmpty) (root, wt, '')]) {
    for (final name in _borrowed) {
      if (Directory('$from/$name').existsSync() &&
          !FileSystemEntity.isLinkSync('$from/$name') &&
          !Directory('$to/$name').existsSync()) {
        await Link('$to/$name').create('$from/$name');
        links.add(prefix.isEmpty ? name : '$prefix/$name');
      }
    }
  }
  return ForkCopy(repoRoot: root, root: wt, path: path, base: base, links: links);
}

Future<List<int>?> _blob(String root, String rev, String path) async {
  final res = await _proc(await guardedArgs(root, ['show', '$rev:$path']), stdoutEncoding: null);
  return res.exitCode == 0 ? res.stdout as List<int> : null;
}

bool _sameBytes(List<int>? a, List<int>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _binary(List<int>? b) => b != null && b.take(8000).contains(0);

Future<ForkMerge> mergeFork(ForkCopy copy, {required String slug, bool merge = true}) async {
  final ref = 'refs/everyai/forks/$slug';
  final wt = copy.root;
  // Everything the fork left, minus the borrowed dependency links.
  await _git(wt, ['add', '-A', '--', '.', for (final l in copy.links) ':(exclude)$l']);
  await _git(wt, [
    '-c', 'user.name=EveryAI', '-c', 'user.email=agent@everyai.invalid', //
    'commit', '-q', '--no-verify', '-m', 'EveryAI fork',
  ], check: false);
  final tip = (await _out(wt, ['rev-parse', 'HEAD'])).trim();
  await _git(copy.repoRoot, ['update-ref', ref, tip]);
  final merged = <String>[];
  final conflicts = <String>[];
  if (merge && tip != copy.base) {
    final changed = await _out(copy.repoRoot, ['diff', '--name-status', '--no-renames', copy.base, tip]);
    final tmp = await Directory.systemTemp.createTemp('everyai-merge');
    try {
      for (final line in const LineSplitter().convert(changed)) {
        final parts = line.split('\t');
        if (parts.length < 2) continue;
        final path = parts.last;
        final target = File('${copy.repoRoot}/$path');
        final ours = target.existsSync() ? await target.readAsBytes() : null;
        final base = await _blob(copy.repoRoot, copy.base, path);
        final theirs = await _blob(copy.repoRoot, tip, path);
        if (_sameBytes(ours, theirs)) {
          merged.add(path);
        } else if (_sameBytes(ours, base)) {
          // Only the fork changed it.
          if (theirs == null) {
            if (target.existsSync()) await target.delete();
          } else {
            await target.parent.create(recursive: true);
            await target.writeAsBytes(theirs);
          }
          merged.add(path);
        } else if (ours == null || theirs == null || _binary(ours) || _binary(theirs) || _binary(base)) {
          // Both changed it and it can't be merged line by line: the parent's version stays.
          conflicts.add(path);
        } else {
          final b = File('${tmp.path}/base')..writeAsBytesSync(base ?? const []);
          final t = File('${tmp.path}/theirs')..writeAsBytesSync(theirs);
          final res = await _proc(dir: copy.repoRoot, [
            ...guardFlags(await _devNull(copy.repoRoot)),
            'merge-file',
            '-p',
            '-L',
            'yours',
            '-L',
            'fork base',
            '-L',
            'fork',
            target.path,
            b.path,
            t.path,
          ], stdoutEncoding: null);
          if (res.exitCode < 0) {
            conflicts.add(path);
            continue;
          }
          await target.writeAsBytes(res.stdout as List<int>);
          (res.exitCode == 0 ? merged : conflicts).add(path);
        }
      }
    } finally {
      await tmp.delete(recursive: true);
    }
  }
  await _git(copy.repoRoot, ['worktree', 'remove', '--force', wt], check: false);
  return (merged: merged, conflicts: conflicts, ref: ref);
}

/// The fork worktrees in [forksDir] that no session holds ([held]: their roots), each with its repository ('' when
/// git can't tell any more) and whether it has work of its own: uncommitted changes (the borrowed dependency links
/// aside) or commits past its base.
Future<List<OrphanFork>> orphanForks(String forksDir, Set<String> held) async {
  final dir = Directory(forksDir);
  if (!dir.existsSync()) return const [];
  final out = <OrphanFork>[];
  // Compared spelled the same way: listSync joins with the platform's separator, sessions store '/'.
  final heldPaths = {for (final h in held) p.canonicalize(h)};
  for (final d in dir.listSync().whereType<Directory>()) {
    if (heldPaths.contains(p.canonicalize(d.path))) continue;
    final common = await _git(d.path, ['rev-parse', '--path-format=absolute', '--git-common-dir'], check: false);
    if (common.exitCode != 0) {
      // Its repository can't be reached (an unmounted disk, a moved project): what it holds can't be told, so it is
      // kept for the user to remove.
      out.add((path: d.path, repoRoot: '', unsaved: true));
      continue;
    }
    final repo = File('${common.stdout}'.trim()).parent.path;
    final status = await _git(d.path, ['status', '--porcelain', '--untracked-files=normal'], check: false);
    final changes = [
      for (final line in const LineSplitter().convert('${status.stdout}'))
        if (line.length > 3 && !_borrowedLink(d.path, line.substring(3).trim().replaceAll(RegExp(r'/$'), ''))) line,
    ];
    final subject = await _git(d.path, ['log', '-1', '--format=%s'], check: false);
    final committed = subject.exitCode == 0 && '${subject.stdout}'.trim() != 'EveryAI fork base';
    out.add((path: d.path, repoRoot: repo, unsaved: changes.isNotEmpty || committed));
  }
  return out;
}

bool _borrowedLink(String root, String path) =>
    _borrowed.contains(path.split('/').last) && FileSystemEntity.isLinkSync('$root/$path');

/// Deletes an orphaned fork worktree: git forgets it, then its folder goes.
Future<void> removeOrphanFork(OrphanFork o) async {
  if (o.repoRoot.isNotEmpty) {
    await _git(o.repoRoot, ['worktree', 'remove', '--force', o.path], check: false);
    await _git(o.repoRoot, ['worktree', 'prune'], check: false);
  }
  final d = Directory(o.path);
  if (d.existsSync()) await d.delete(recursive: true);
}

// --------------------------------------------------------- landing lanes

/// The fork's own last commit for what it left uncommitted (see [mergeFork]): not one of the lane's commits.
bool _isForkLeftover(String email, String subject) => email == 'agent@everyai.invalid' && subject == 'EveryAI fork';

/// Cherry-picks [commit] onto [onto] without touching the folder or the index (`git merge-tree`, git 2.40+): the
/// new commit, keeping the author, date and message (AI-credit lines removed), signed when [sign]; [onto] itself
/// when the commit changes nothing there (its change is in already: no empty duplicate); null when it doesn't apply
/// cleanly. Throws a [GitError] when this git can't do it, a [_SignFailed] when signing fails.
Future<String?> _replay(String top, String commit, String onto, {bool sign = false}) async {
  final res = await _git(top, ['merge-tree', '--write-tree', '--merge-base=$commit^', onto, commit], check: false);
  if (res.exitCode == 1) return null;
  if (res.exitCode != 0) throw GitError('git merge-tree: ${'${res.stderr}'.trim()}');
  final tree = '${res.stdout}'.split('\n').first.trim();
  if (tree == await _out(top, ['rev-parse', '$onto^{tree}'])) return onto;
  final meta = (await _out(top, ['log', '-1', '--format=%an%x00%ae%x00%ad', '--date=raw', commit])).split('\x00');
  final message = stripBranding((await _git(top, ['log', '-1', '--format=%B', commit])).stdout as String);
  return _commitTree(top, tree, onto, message, author: (name: meta[0], email: meta[1], date: meta[2]), sign: sign);
}

/// A landing commit that `commit.gpgSign` asks to sign and that couldn't be signed: nothing is landed unsigned.
final class _SignFailed implements Exception {
  const _SignFailed(this.detail);
  final String detail;
}

/// Whether the user's config asks for signed commits in [top] (`commit.gpgSign`; the signing program is the
/// user's own, see [repoGuard]).
Future<bool> _signs(String top) async =>
    '${(await _git(top, ['config', '--bool', '--get', 'commit.gpgsign'], check: false)).stdout}'.trim() == 'true';

/// A commit of [tree] on [parent] with [message], signed when [sign]; the author is the configured identity unless
/// [author] is given. Runs guarded, like every EveryAI git call.
Future<String> _commitTree(
  String top,
  String tree,
  String parent,
  String message, {
  ({String name, String email, String date})? author,
  bool sign = false,
}) async {
  final env = {
    if (author != null) ...{
      'GIT_AUTHOR_NAME': author.name,
      'GIT_AUTHOR_EMAIL': author.email,
      'GIT_AUTHOR_DATE': author.date,
    },
  };
  try {
    return (await _piped(
      top,
      ['commit-tree', tree, '-p', parent, if (sign) '-S', '-F', '-'],
      message.trim().isEmpty ? 'Workflow lane\n' : message,
      env: env,
    )).trim();
  } on GitError catch (e) {
    if (sign) throw _SignFailed(e.message);
    rethrow;
  }
}

Future<LaneLanding> landWithCommits(
  SessionWorktree w, {
  required List<LaneRef> lanes,
  required List<String> paths,
  required String message,
  String? newBranch,
}) async {
  final name = newBranch?.trim();
  if (name != null) {
    if ((await _git(w.path, ['check-ref-format', '--branch', name], check: false)).exitCode != 0 ||
        name.startsWith('-')) {
      throw GitError('"$name" is not a branch name git accepts.');
    }
    if ((await _git(w.path, ['show-ref', '--verify', '--quiet', 'refs/heads/$name'], check: false)).exitCode == 0) {
      throw GitError('There is a branch called $name already.');
    }
  }
  // Paths from git diffs are relative to the top of the checkout.
  final top = await _out(w.path, ['rev-parse', '--show-toplevel']);
  final head = await _out(top, ['rev-parse', 'HEAD']);
  // The branch HEAD is on ('' when detached): landing goes nowhere if it changes meanwhile.
  final onRef = '${(await _git(top, ['symbolic-ref', '-q', 'HEAD'], check: false)).stdout}'.trim();
  final sign = await _signs(top);
  try {
    return await _land(top, head, onRef, lanes, paths, message, name, sign: sign);
  } on _SignFailed catch (e) {
    throw GitError(
      'Your git config signs commits (commit.gpgSign), and signing failed, so nothing was committed and the files '
              'are as they were. Fix signing (or turn commit.gpgSign off) and try again. ${e.detail}'
          .trim(),
    );
  }
}

Future<LaneLanding> _land(
  String top,
  String head,
  String onRef,
  List<LaneRef> lanes,
  List<String> paths,
  String message,
  String? name, {
  required bool sign,
}) async {
  var cur = head;
  var replayed = 0;
  final notes = <String>[];
  final touched = <String>{};
  var gitTooOld = false;
  for (final lane in lanes) {
    if (gitTooOld) break;
    final log = await _git(top, [
      'log',
      '--reverse',
      '--topo-order',
      '--format=%H%x00%P%x00%ae%x00%s',
      '${lane.base}..${lane.ref}',
    ], check: false);
    if (log.exitCode != 0) {
      notes.add('${lane.label}: its commits are gone, so its changes are in the last commit.');
      continue;
    }
    final commits = [
      for (final l in const LineSplitter().convert('${log.stdout}'))
        if (l.split('\x00') case [final sha, final parents, final email, final subject])
          (sha: sha, merge: parents.contains(' '), leftover: _isForkLeftover(email, subject)),
    ].where((c) => !c.leftover).toList();
    if (commits.isEmpty) continue;
    if (commits.any((c) => c.merge)) {
      notes.add('${lane.label}: it has merge commits, so its changes are in the last commit.');
      continue;
    }
    var laneCur = cur;
    var laneMade = 0;
    var clean = true;
    try {
      for (final c in commits) {
        final next = await _replay(top, c.sha, laneCur, sign: sign);
        if (next == null) {
          clean = false;
          break;
        }
        if (next != laneCur) laneMade++;
        laneCur = next;
      }
    } on GitError {
      gitTooOld = true;
      notes.add(
        'This git cannot replay commits without touching the folder (it needs git 2.40 or later), so the '
        'lanes\' changes are in the last commit.',
      );
      break;
    }
    if (!clean) {
      notes.add("${lane.label}: its commits didn't apply on top of the others, so its changes are in the last commit.");
      continue;
    }
    for (final c in commits) {
      final out = await _out(top, ['diff-tree', '--no-commit-id', '--name-only', '--no-renames', '-r', '-z', c.sha]);
      touched.addAll(out.split('\x00').where((p) => p.isNotEmpty));
    }
    cur = laneCur;
    replayed += laneMade;
  }
  // The last commit: the folder's state of every path the run or a replayed lane touched, so the branch ends where
  // the folder is (the integrate step's work, conflict fixes, lanes that weren't replayed).
  final all = {...paths, ...touched}.toList()..sort();
  final tmp = await Directory.systemTemp.createTemp('everyai-land');
  try {
    final env = {'GIT_INDEX_FILE': '${tmp.path}/index'};
    await _git(top, ['read-tree', cur], env: env);
    if (all.isNotEmpty) {
      // Guarded: the repository's filters and index hooks don't run (a clean filter refuses, see [repoGuard]).
      await _piped(top, ['update-index', '--add', '--remove', '-z', '--stdin'], '${all.join('\x00')}\x00', env: env);
    }
    final tree = await _out(top, ['write-tree'], env: env);
    if (tree != await _out(top, ['rev-parse', '$cur^{tree}'])) {
      cur = await _commitTree(top, tree, cur, stripBranding(message), sign: sign);
    }
  } finally {
    await tmp.delete(recursive: true);
  }
  if (cur == head) return (head: null, laneCommits: 0, notes: notes);
  // Nothing moved HEAD (a commit, a switch) while the commits were made.
  final nowRef = '${(await _git(top, ['symbolic-ref', '-q', 'HEAD'], check: false)).stdout}'.trim();
  if (nowRef != onRef || await _out(top, ['rev-parse', 'HEAD']) != head) {
    throw const GitError(
      'The checkout moved (a commit or a branch switch) while EveryAI was landing, so nothing was landed. '
      'Try again.',
    );
  }
  if (name != null) {
    // Create-only: an empty old value fails when the branch appeared meanwhile.
    await _git(top, ['update-ref', '-m', 'EveryAI: land a workflow on $name', 'refs/heads/$name', cur, '']);
    await _git(top, ['symbolic-ref', '-m', 'EveryAI: land a workflow on $name', 'HEAD', 'refs/heads/$name']);
  } else {
    // Moves the branch HEAD is on (or a detached HEAD), only if nothing moved it meanwhile.
    await _git(top, ['update-ref', '-m', 'EveryAI: land a workflow', 'HEAD', cur, head]);
  }
  // The index matches the new commit on those paths; the user's own staging elsewhere is kept. The paths are
  // literal (a file named `b*` is not a pattern) and go on stdin (no argument limit).
  if (all.isNotEmpty) {
    try {
      await _piped(
        top,
        ['reset', '-q', cur, '--pathspec-from-file=-', '--pathspec-file-nul'],
        '${all.join('\x00')}\x00',
        env: const {'GIT_LITERAL_PATHSPECS': '1'},
      );
    } on GitError {
      // The commit landed; a stale index entry only shows as staged.
    }
  }
  return (head: cur, laneCommits: replayed, notes: notes);
}

/// Git's empty tree, the base for a repository with no commit yet.
const _emptyTree = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';
