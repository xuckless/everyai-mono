import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../code_providers.dart';
import '../git/git_service.dart';

/// Fork worktrees left in the app's `forks` folder with no session holding them (the app quit mid-run, or the
/// session went). The first read (the shell's, at launch on desktop) prunes them: those with no work of their own
/// are deleted; those with uncommitted changes or commits past their base are kept and listed here, for Settings →
/// Code to remove one by one.
final orphanForksProvider = AsyncNotifierProvider<OrphanForks, List<OrphanFork>>(OrphanForks.new);

class OrphanForks extends AsyncNotifier<List<OrphanFork>> {
  @override
  Future<List<OrphanFork>> build() async {
    final dir = '${await ref.read(driverDataDirProvider)()}/forks';
    final held = {
      for (final s in ref.read(codeSessionsProvider))
        if (s.forkCopy case final f?) f.root,
    };
    final found = await GitService.orphanForks(dir, held);
    for (final o in found.where((o) => !o.unsaved)) {
      try {
        await GitService.removeOrphanFork(o);
      } on Object {
        // Left for the next launch.
      }
    }
    return [...found.where((o) => o.unsaved)];
  }

  /// Deletes [o] (the user's Remove).
  Future<void> remove(OrphanFork o) async {
    await GitService.removeOrphanFork(o);
    state = AsyncData([...?state.value?.where((x) => x.path != o.path)]);
  }
}
