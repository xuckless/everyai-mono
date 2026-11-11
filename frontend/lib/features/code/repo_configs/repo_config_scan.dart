// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import '../domain/cli_repo_configs.dart';

/// [cliRepoConfigs] for the project at [dir], with the digest of what they hold ([repoConfigDigest]); null when
/// there are none. Reads only (nothing in them runs). A folder counts each file beneath it, up to [maxFiles].
Future<({List<RepoConfigFile> files, String digest})?> scanRepoConfigs(
  RepoConfigCli cli,
  String dir, {
  int maxFiles = 200,
}) async {
  final tree = _DiskTree(dir);
  final files = cliRepoConfigs(cli, tree);
  if (files.isEmpty) return null;
  final contents = <String, String>{};
  for (final f in files) {
    if (!f.path.endsWith('/')) {
      contents[f.path] = tree.read(f.path) ?? '';
      continue;
    }
    final folder = Directory('$dir/${f.path}');
    try {
      await for (final e in folder.list(recursive: true, followLinks: false)) {
        if (contents.length >= maxFiles) break;
        if (e is! File) continue;
        final rel = e.path.substring(dir.length + 1);
        try {
          contents[rel] = await e.readAsString();
        } on FileSystemException {
          contents[rel] = '(unreadable)';
        } on FormatException {
          contents[rel] = '${await e.length()} bytes';
        }
      }
    } on FileSystemException {
      contents[f.path] = '(unreadable)';
    }
  }
  return (files: files, digest: repoConfigDigest(contents));
}

final class _DiskTree implements RepoTree {
  _DiskTree(this.dir);
  final String dir;

  @override
  String? read(String path) {
    try {
      final f = File('$dir/$path');
      if (!f.existsSync()) return null;
      // A config file is small; a huge one still counts as there, unread.
      if (f.lengthSync() > 1 << 20) return '';
      return f.readAsStringSync();
    } on FileSystemException {
      return null;
    } on FormatException {
      return '';
    }
  }

  @override
  bool isDir(String path) => Directory('$dir/$path').existsSync();
}
