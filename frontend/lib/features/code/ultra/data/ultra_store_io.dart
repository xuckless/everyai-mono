import 'dart:convert';
import 'dart:io';

import '../../git/git_service.dart';
import '../domain/ultra_engine.dart';
import '../domain/ultra_journal.dart';

UltraJournalStore journalStore(String dataDir) => FileJournalStore(Directory('$dataDir/ultra'));

Future<List<String>> runIds(String dataDir) async {
  final dir = Directory('$dataDir/ultra');
  if (!dir.existsSync()) return const [];
  final files = [
    for (final f in dir.listSync())
      if (f is File && f.path.endsWith('.json')) f,
  ]..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  return [for (final f in files) f.uri.pathSegments.last.replaceAll('.json', '')];
}

UltraWorkspace workspace({required SessionWorktree? base, required String dataDir}) =>
    GitUltraWorkspace(base: base, dataDir: dataDir);

Future<bool> saveBase(SessionWorktree base) => GitService.commitAll(base, 'Save the session before an Ultra run');

/// One JSON file per run, replaced whole on every save (write, then rename).
final class FileJournalStore implements UltraJournalStore {
  FileJournalStore(this.dir);
  final Directory dir;

  File _file(String runId) => File('${dir.path}/${_safe(runId)}.json');

  @override
  Future<void> save(UltraJournal journal) async {
    await dir.create(recursive: true);
    final file = _file(journal.runId);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(journal.toJson()), flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<UltraJournal?> load(String runId) async {
    final file = _file(runId);
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      return json is Map<String, Object?> ? UltraJournal.fromJson(json) : null;
    } on FormatException {
      return null;
    }
  }
}

/// Step worktrees on `everyai/ultra-<run>-<step>` branches of the session's
/// repository, made from the session worktree's current commit and merged
/// back into it (a merge commit, so each step's history stays). A step whose
/// merge conflicts keeps its branch for the user; its folder is removed.
final class GitUltraWorkspace implements UltraWorkspace {
  GitUltraWorkspace({required this.base, required this.dataDir});

  final SessionWorktree? base;
  final String dataDir;

  @override
  bool get isolates => base != null;

  String get _hooks => '$dataDir/git-hooks';

  @override
  Future<StepWorktree> create(String runId, String key) async {
    final b = base!;
    final run = _short(runId);
    final w = await GitService.createWorktree(
      // Created from the session worktree, so it starts at that commit.
      repoRoot: b.path,
      slug: 'ultra-$run-${_safe(key)}',
      worktreesDir: '$dataDir/worktrees/ultra-$run',
      hooksDir: _hooks,
    );
    return StepWorktree(path: w.path, branch: w.branch);
  }

  @override
  Future<MergeOutcome> merge(StepWorktree w, String message) async {
    final b = base!;
    final step = SessionWorktree(
      repoRoot: b.path,
      path: w.path,
      branch: w.branch,
      baseBranch: b.branch,
      baseCommit: '',
    );
    await GitService.commitAll(step, message);
    // Steps never write the session's folder, but the user might have.
    await GitService.commitAll(b, 'Save the session before merging an Ultra step');
    final ahead = await _git(b.path, ['rev-list', '--count', 'HEAD..${w.branch}']);
    if (ahead.exitCode == 0 && '${ahead.stdout}'.trim() == '0') {
      await GitService.removeWorktree(step, hooksDir: _hooks);
      return MergeOutcome(merged: true, branch: w.branch, detail: 'no changes');
    }
    final res = await _git(b.path, ['merge', '--no-ff', '--no-edit', '-m', message, w.branch]);
    if (res.exitCode == 0) {
      await GitService.removeWorktree(step, hooksDir: _hooks);
      return MergeOutcome(merged: true, branch: w.branch);
    }
    final conflicts = await _git(b.path, ['diff', '--name-only', '--diff-filter=U']);
    await _git(b.path, ['merge', '--abort']);
    // Keep the branch (the user's to merge by hand); drop the folder.
    await GitService.removeWorktree(step, hooksDir: _hooks, deleteBranch: false);
    final files = '${conflicts.stdout}'.trim().split('\n').where((f) => f.isNotEmpty).toList();
    return MergeOutcome(
      merged: false,
      branch: w.branch,
      detail: files.isEmpty ? '${res.stderr}'.trim() : 'conflicts in ${files.join(', ')}',
    );
  }

  static Future<ProcessResult> _git(String dir, List<String> args) => Process.run('git', ['-C', dir, ...args]);
}

String _short(String id) => _safe(id.length <= 8 ? id : id.substring(id.length - 8));

/// A file and branch name part: `phase.step[2]` becomes `phase-step-2`.
String _safe(String s) => s
    .toLowerCase()
    .replaceAll(RegExp('[^a-z0-9_-]+'), '-')
    .replaceAll(RegExp('-+'), '-')
    .replaceAll(RegExp(r'^-|-$'), '');
