// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'migration_files_stub.dart' if (dart.library.io) 'migration_files_io.dart' as impl;
import 'migration_roots.dart';
import 'migration_scan.dart';

export 'migration_roots.dart';

/// Reads the other tools' files (read-only; nothing is ever written there) and returns what it found: their
/// user-level config under [roots], and for each of [projectPaths] the files in that folder. On the web there is
/// nothing to read.
Future<List<ImportItem>> scanOtherTools(MigrationRoots roots, List<String> projectPaths) =>
    impl.scan(roots, projectPaths);
