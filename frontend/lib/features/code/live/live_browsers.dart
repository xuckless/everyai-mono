// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../harness/everyai/browser_io.dart';
import 'browser_jar.dart';
import 'login_wall.dart';

/// The shared browser page of each Code session: the one the agent drives (the EveryAI harness's browser tool, or
/// the host's for an outside lead) and the Preview paints, so user and agent see and use the same page. It runs in
/// the project's Chrome ([browserProfileDir]) but in a context of its own: each session has its own cookies and
/// storage (its jar, kept sealed between runs), and starts from a saved login when the user picks one.
abstract final class LiveBrowsers {
  static final _bySession = <String, HeadlessBrowser>{};
  static final _changes = StreamController<String>.broadcast();

  /// A session whose browser was made or released.
  static Stream<String> get changes => _changes.stream;

  /// Where sessions' jars and saved logins are sealed; set at app start. Null (tests): sessions share the profile's
  /// cookies, as before jars.
  static Future<SealedStore> Function()? jars;

  /// Session [liveId]'s browser, made on first use with [profileDir].
  static HeadlessBrowser forSession(String liveId, {required String profileDir}) {
    if (_bySession[liveId] case final b?) return b;
    final store = jars;
    final b = HeadlessBrowser(
      profileDir: profileDir,
      jarHome: store == null ? null : (store: store, name: 'jar-$liveId'),
    );
    _bySession[liveId] = b;
    if (store != null) _watchExpiry(b, store);
    _changes.add(liveId);
    return b;
  }

  /// A site asks [b]'s session to sign in again although it started from a saved login for it: that login expired.
  static void _watchExpiry(HeadlessBrowser b, Future<SealedStore> Function() store) {
    b.loginWall.state.addListener(() {
      if (b.loginWall.state.value case WallWaiting(:final site)) {
        if (b.usedLogins[site] case final id?) {
          unawaited(store().then((s) => SavedLogins.of(s).markExpired(id)).catchError((Object _) {}));
        }
      }
    });
  }

  /// The saved logins [b]'s session started from get its refreshed sign-ins (while it is still signed in).
  static Future<void> _writeBack(HeadlessBrowser b) async {
    final store = jars;
    if (store == null || b.usedLogins.isEmpty) return;
    try {
      final jar = await b.captureJar();
      final logins = SavedLogins.of(await store());
      for (final MapEntry(key: site, value: id) in b.usedLogins.entries) {
        await logins.writeBack(id, jarForSite(jar, site));
      }
    } on Object {
      // Kept as saved.
    }
  }

  /// Session [liveId]'s browser if it has one.
  static HeadlessBrowser? of(String liveId) => _bySession[liveId];

  /// Closes session [liveId]'s page: the session was removed, so its jar goes too (its saved logins get their
  /// refreshed sign-ins first). A session that was never opened this run has only its jar file.
  static Future<void> release(String liveId) async {
    final b = _bySession.remove(liveId);
    if (b == null) {
      final store = jars;
      if (store != null) unawaited(store().then((s) => s.delete('jar-$liveId')).catchError((Object _) {}));
      return;
    }
    _changes.add(liveId);
    b.loginWall.stop();
    await _writeBack(b);
    await b.forgetJar();
    await b.close();
  }

  /// Stops every browser (the app quits).
  static Future<void> stopAll() async {
    final all = [..._bySession.values];
    _bySession.clear();
    // Jars and saved logins first (close() saves the jar), then the pages, then Chrome.
    await Future.wait([for (final b in all) _writeBack(b).then((_) => b.close()).then((_) => b.host.stop())]);
  }
}

/// Where project [projectDir]'s browser profile lives under the app's data folder [dataDir].
String browserProfileDir(String dataDir, String projectDir) =>
    '$dataDir/browser-profiles/${sha1.convert(utf8.encode(projectDir)).toString().substring(0, 16)}';
