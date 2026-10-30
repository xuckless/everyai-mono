import '../../git/git_models.dart';
import '../domain/ultra_engine.dart';
import 'ultra_store_stub.dart' if (dart.library.io) 'ultra_store_io.dart' as impl;

/// Journals under app support `ultra/<run id>.json`.
UltraJournalStore ultraJournalStore(String dataDir) => impl.journalStore(dataDir);

/// The run ids with a journal on disk, newest first.
Future<List<String>> ultraRunIds(String dataDir) => impl.runIds(dataDir);

/// Step worktrees branched from the session's worktree [base] (null when the
/// session's folder isn't a git repository) under app support
/// `worktrees/ultra-<run>/`.
UltraWorkspace ultraWorkspace({required SessionWorktree? base, required String dataDir}) =>
    impl.workspace(base: base, dataDir: dataDir);

/// Commits what the session's worktree holds before a run, so step
/// worktrees start from it. False when there was nothing to commit.
Future<bool> ultraSaveBase(SessionWorktree base) => impl.saveBase(base);
