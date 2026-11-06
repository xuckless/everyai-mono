// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../harness/everyai/browser_io.dart';

/// The shared browser page of each Code session: the one the agent drives (the EveryAI harness's browser tool, or
/// the host's for an outside lead) and the Preview paints, so user and agent see and use the same page. Its profile
/// is the project's ([browserProfileDir]): sign-ins carry over between the project's sessions.
abstract final class LiveBrowsers {
  static final _bySession = <String, HeadlessBrowser>{};
  static final _changes = StreamController<String>.broadcast();

  /// A session whose browser was made or released.
  static Stream<String> get changes => _changes.stream;

  /// Session [liveId]'s browser, made on first use with [profileDir].
  static HeadlessBrowser forSession(String liveId, {required String profileDir}) {
    if (_bySession[liveId] case final b?) return b;
    final b = HeadlessBrowser(profileDir: profileDir);
    _bySession[liveId] = b;
    _changes.add(liveId);
    return b;
  }

  /// Session [liveId]'s browser if it has one.
  static HeadlessBrowser? of(String liveId) => _bySession[liveId];

  /// Closes session [liveId]'s page (the session was removed).
  static Future<void> release(String liveId) async {
    final b = _bySession.remove(liveId);
    if (b == null) return;
    _changes.add(liveId);
    await b.close();
  }

  /// Stops every browser (the app quits).
  static Future<void> stopAll() async {
    final all = [..._bySession.values];
    _bySession.clear();
    await Future.wait([for (final b in all) b.close().then((_) => b.host.stop())]);
  }
}

/// Where project [projectDir]'s browser profile lives under the app's data folder [dataDir].
String browserProfileDir(String dataDir, String projectDir) =>
    '$dataDir/browser-profiles/${sha1.convert(utf8.encode(projectDir)).toString().substring(0, 16)}';
