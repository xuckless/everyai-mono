import '../../git/git_models.dart';
import '../domain/ultra_engine.dart';
import '../domain/ultra_journal.dart';

UltraJournalStore journalStore(String dataDir) => _NoStore();
Future<List<String>> runIds(String dataDir) async => const [];
UltraWorkspace workspace({required SessionWorktree? base, required String dataDir}) => _NoWorkspace();
Future<bool> saveBase(SessionWorktree base) async => false;

final class _NoStore implements UltraJournalStore {
  @override
  Future<void> save(UltraJournal journal) async {}

  @override
  Future<UltraJournal?> load(String runId) async => null;
}

final class _NoWorkspace implements UltraWorkspace {
  @override
  bool get isolates => false;

  @override
  Future<StepWorktree> create(String runId, String key) => throw UnsupportedError('Worktrees need the desktop app.');

  @override
  Future<MergeOutcome> merge(StepWorktree w, String message) =>
      throw UnsupportedError('Worktrees need the desktop app.');
}
