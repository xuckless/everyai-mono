// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, visibleForTesting;

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
  static final _bySession = <String, BrowserPage>{};
  static final _changes = StreamController<String>.broadcast();

  /// A session whose browser was made or released.
  static Stream<String> get changes => _changes.stream;

  /// Where sessions' jars and saved logins are sealed; set at app start. Null (tests): sessions share the profile's
  /// cookies, as before jars.
  static Future<SealedStore> Function()? jars;

  /// Session [liveId]'s browser, made on first use with [profileDir].
  static BrowserPage forSession(String liveId, {required String profileDir}) {
    if (_bySession[liveId] case final b?) return b;
    final store = jars;
    final b = makeSessionBrowser(
      backendFor(defaultTargetPlatform),
      profileDir: profileDir,
      jarHome: store == null ? null : (store: store, name: 'jar-$liveId'),
    );
    _bySession[liveId] = b;
    if (store != null) _watchExpiry(b, store);
    _changes.add(liveId);
    return b;
  }

  /// A site asks [b]'s session to sign in again although it started from a saved login for it: that login expired.
  /// (The card still offers it: a wall can be wrong.)
  static void _watchExpiry(BrowserPage b, Future<SealedStore> Function() store) {
    b.loginWall.state.addListener(() {
      if (b.loginWall.state.value case WallWaiting(:final site)) {
        if (b.usedLogins[site] case final id?) {
          unawaited(store().then((s) => SavedLogins.of(s).markExpired(id)).catchError((Object _) {}));
        }
      }
    });
  }

  /// The saved logins [b]'s session started from get its refreshed sign-ins (while it is still signed in). A login
  /// the site asked to sign in to again this session (the wall marked it expired) is left as it is unless the user
  /// signed in past that wall: what's left then is the site's signed-out cookies. [jar]: read just now.
  static Future<void> _writeBack(BrowserPage b, {JarData? jar}) async {
    final store = jars;
    if (store == null || b.usedLogins.isEmpty) return;
    try {
      final now = jar ?? await b.captureJar();
      final logins = SavedLogins.of(await store());
      for (final MapEntry(key: site, value: id) in b.usedLogins.entries) {
        final outcome = b.loginWall.lastOutcome(site);
        if (outcome != null && outcome != WallOutcome.passed) continue;
        await logins.writeBack(id, jarForSite(now, site), renewed: outcome == WallOutcome.passed);
      }
    } on Object {
      // Kept as saved.
    }
  }

  /// Project [projectId] was removed: its own saved logins go with it (logins for every project stay).
  static Future<void> forgetProjectLogins(String projectId) async {
    final store = jars;
    if (store == null) return;
    try {
      await SavedLogins.of(await store()).forgetProject(projectId);
    } on Object {
      // No keychain: they stay until the project's logins can be opened.
    }
  }

  /// Every session's browser this run.
  static Iterable<BrowserPage> get all => _bySession.values;

  /// Session [liveId]'s browser if it has one.
  static BrowserPage? of(String liveId) => _bySession[liveId];

  /// A browser for session [liveId] without starting Chrome (tests); null takes it away.
  @visibleForTesting
  static void debugSet(String liveId, BrowserPage? b) => b == null ? _bySession.remove(liveId) : _bySession[liveId] = b;

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
    // Each jar is read once (the quit has a few seconds): its saved logins get it, close() saves it, then Chrome.
    Future<void> stop(BrowserPage b) async {
      final jar = b.jarHome == null ? null : await b.captureJar().catchError((Object _) => emptyJar);
      if (jar != null) await _writeBack(b, jar: jar);
      await b.close(captured: jar != null);
      // Chrome itself stops with its profile's last page.
      if (b case final HeadlessBrowser chrome) await chrome.host.stop();
    }

    await Future.wait([for (final b in all) stop(b)]);
    // Profiles opened outside a session's page (sign-in, an agent's own browser) too.
    await ChromeHost.stopAll();
  }
}

/// A session's page made with [backend]: the one place that picks what runs it.
BrowserPage makeSessionBrowser(BrowserBackend backend, {required String profileDir, JarHome? jarHome}) =>
    switch (backend) {
      BrowserBackend.chromeStream => HeadlessBrowser(profileDir: profileDir, jarHome: jarHome),
      BrowserBackend.osWebview => throw UnsupportedError('The OS webview backend is not built yet.'),
    };

/// Where project [projectDir]'s browser profile lives under the app's data folder [dataDir].
String browserProfileDir(String dataDir, String projectDir) =>
    '$dataDir/browser-profiles/${sha1.convert(utf8.encode(projectDir)).toString().substring(0, 16)}';
