// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'login_wall.dart' show siteOf;

// Sign-ins the session browser keeps: each session's own cookie jar (cookies and local storage, kept between app
// runs), and saved logins: one site's sign-in the user saved for the project or for every project, which a session can
// start from. Both are sealed on disk (AES-GCM, with a key in the OS keychain), never in plain files.

/// Cookies as DevTools gives them (`Storage.getCookies`), and local storage by origin.
typedef JarData = ({List<Map<String, Object?>> cookies, Map<String, Map<String, String>> storage});

const emptyJar = (cookies: <Map<String, Object?>>[], storage: <String, Map<String, String>>{});

Map<String, Object?> jarToJson(JarData j) => {'cookies': j.cookies, 'storage': j.storage};

JarData jarFromJson(Object? json) {
  if (json is! Map) return emptyJar;
  return (
    cookies: [
      for (final c in (json['cookies'] as List?) ?? const [])
        if (c is Map) c.cast<String, Object?>(),
    ],
    storage: {
      for (final MapEntry(:key, :value) in ((json['storage'] as Map?) ?? const {}).entries)
        if (value is Map) '$key': {for (final e in value.entries) '${e.key}': '${e.value}'},
    },
  );
}

/// The part of [j] for [site] ("github.com"): its cookies (any subdomain) and the storage of its origins.
JarData jarForSite(JarData j, String site) => (
  cookies: [
    for (final c in j.cookies)
      if (siteOf('${c['domain'] ?? ''}') == site) c,
  ],
  storage: {
    for (final e in j.storage.entries)
      if (siteOf(Uri.tryParse(e.key)?.host ?? '') == site) e.key: e.value,
  },
);

/// [j] without [site]'s part.
JarData jarWithoutSite(JarData j, String site) => (
  cookies: [
    for (final c in j.cookies)
      if (siteOf('${c['domain'] ?? ''}') != site) c,
  ],
  storage: {
    for (final e in j.storage.entries)
      if (siteOf(Uri.tryParse(e.key)?.host ?? '') != site) e.key: e.value,
  },
);

/// [a] with [b] over it (a saved login applied to a session's jar).
JarData jarMerged(JarData a, JarData b) {
  String key(Map<String, Object?> c) => '${c['name']}|${c['domain']}|${c['path']}';
  final cookies = {for (final c in a.cookies) key(c): c, for (final c in b.cookies) key(c): c};
  return (
    cookies: cookies.values.toList(),
    storage: {
      ...a.storage,
      for (final e in b.storage.entries) e.key: {...?a.storage[e.key], ...e.value},
    },
  );
}

/// The sites [j] holds a sign-in for (sites with cookies), most cookies first.
List<String> jarSites(JarData j) {
  final count = <String, int>{};
  for (final c in j.cookies) {
    final s = siteOf('${c['domain'] ?? ''}');
    if (s.isNotEmpty) count[s] = (count[s] ?? 0) + 1;
  }
  return count.keys.toList()..sort((a, b) => count[b]!.compareTo(count[a]!));
}

/// [cookie] (from `Storage.getCookies`) as `Storage.setCookies` takes it; expired ones are dropped (null).
Map<String, Object?>? cookieParam(Map<String, Object?> cookie, {DateTime? now}) {
  final expires = (cookie['expires'] as num?)?.toDouble() ?? -1;
  final session = cookie['session'] == true || expires <= 0;
  final at = (now ?? DateTime.now()).millisecondsSinceEpoch / 1000;
  if (!session && expires < at) return null;
  return {
    'name': cookie['name'],
    'value': cookie['value'],
    'domain': cookie['domain'],
    'path': cookie['path'] ?? '/',
    'secure': cookie['secure'] == true,
    'httpOnly': cookie['httpOnly'] == true,
    if (cookie['sameSite'] case final String s) 'sameSite': s,
    if (!session) 'expires': expires,
    if (cookie['priority'] case final String p) 'priority': p,
    if (cookie['partitionKey'] case final Map<String, Object?> k) 'partitionKey': k,
  };
}

/// The page's own origin and its local storage, read by the app (not the agent) to keep the session's jar.
const storageReadJs =
    '(() => { try { if (!/^https?:/.test(location.protocol)) return null; '
    'return [location.origin, Object.fromEntries(Object.entries(localStorage))]; } catch (_) { return null; } })()';

/// Files sealed with AES-GCM; the key lives in the OS keychain (made on first use).
class SealedStore {
  SealedStore(this.dir, this._key);

  /// Where the files go, and the key.
  final String dir;
  final Future<SecretKey> Function() _key;

  /// The app's store; tests set [override].
  static SealedStore? override;
  static SealedStore? _app;

  /// The store under the app's data folder [dataDir], keyed from the keychain.
  static SealedStore app(String dataDir) => override ?? (_app ??= SealedStore('$dataDir/browser', _keychainKey));

  static const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: !kDebugMode));
  static const _keyName = 'browser.sealed_key';
  static Future<SecretKey>? _keyFuture;

  static Future<SecretKey> _keychainKey() => _keyFuture ??=
      () async {
        final have = await _storage.read(key: _keyName);
        if (have != null) return SecretKey(base64Decode(have));
        final r = Random.secure();
        final bytes = List<int>.generate(32, (_) => r.nextInt(256));
        await _storage.write(key: _keyName, value: base64Encode(bytes));
        return SecretKey(bytes);
      }().catchError((Object e) {
        // A refused keychain prompt: asked again next time, not for the rest of the run.
        _keyFuture = null;
        throw e;
      });

  static final _aes = AesGcm.with256bits();

  File _file(String name) => File('$dir/${name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.sealed');

  /// The write in flight for each name: writes to one name run one after another.
  final _writes = <String, Future<void>>{};
  var _tmpCount = 0;

  /// Seals [json] into [name]. Writes to one name are queued, each through a temporary file of its own, so two at
  /// once (every session saving at quit) never publish a half-written file.
  Future<void> write(String name, Object? json) {
    final prev = _writes[name] ?? Future<void>.value();
    final next = prev.then((_) => _write(name, json), onError: (Object _) => _write(name, json));
    final tracked = next.then<void>((_) {}, onError: (Object _) {});
    _writes[name] = tracked;
    unawaited(
      tracked.whenComplete(() {
        if (identical(_writes[name], tracked)) _writes.remove(name);
      }),
    );
    return next;
  }

  Future<void> _write(String name, Object? json) async {
    final box = await _aes.encrypt(utf8.encode(jsonEncode(json)), secretKey: await _key());
    final f = _file(name);
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.$pid-${_tmpCount++}-${Random().nextInt(1 << 32)}.tmp');
    try {
      await tmp.writeAsBytes(box.concatenation(), flush: true);
      await tmp.rename(f.path);
    } on Object {
      if (tmp.existsSync()) tmp.deleteSync();
      rethrow;
    }
  }

  /// [name]'s content, or null when there is none or it can't be opened (another key: a new keychain). A key that
  /// can't be had (a refused keychain prompt) throws, so the caller asks again next time.
  Future<Object?> read(String name) async {
    final f = _file(name);
    if (!f.existsSync()) return null;
    final SecretBox box;
    try {
      box = SecretBox.fromConcatenation(
        await f.readAsBytes(),
        nonceLength: _aes.nonceLength,
        macLength: _aes.macAlgorithm.macLength,
      );
    } on Object {
      return null;
    }
    final key = await _key();
    try {
      return jsonDecode(utf8.decode(await _aes.decrypt(box, secretKey: key)));
    } on Object {
      return null;
    }
  }

  /// Whether [name] has a file (one [read] may still fail to open).
  bool exists(String name) => _file(name).existsSync();

  Future<void> delete(String name) async {
    if (_writes[name] case final w?) await w;
    final f = _file(name);
    if (f.existsSync()) await f.delete();
  }
}

/// Where a session browser keeps its jar: [name] in [store] (found when the browser starts).
typedef JarHome = ({Future<SealedStore> Function() store, String name});

// ------------------------------------------------------------------------------------------------- saved logins

/// Who may start from a saved login: every project, or one.
enum LoginScope { global, project }

/// A saved login: one site's sign-in. Its cookies and storage are sealed apart ([SavedLogins.payload]).
typedef SavedLogin = ({
  String id,
  String site,
  LoginScope scope,
  String? projectId,
  DateTime saved,

  /// The site asked to sign in again after a session started from it: "Expired: sign in again".
  bool expired,
});

Map<String, Object?> _loginJson(SavedLogin l) => {
  'id': l.id,
  'site': l.site,
  'scope': l.scope.name,
  'project': l.projectId,
  'saved': l.saved.toIso8601String(),
  'expired': l.expired,
};

SavedLogin? _loginFrom(Object? j) {
  if (j is! Map) return null;
  final id = j['id'], site = j['site'];
  if (id is! String || site is! String) return null;
  return (
    id: id,
    site: site,
    scope: j['scope'] == 'project' ? LoginScope.project : LoginScope.global,
    projectId: j['project'] as String?,
    saved: DateTime.tryParse('${j['saved']}') ?? DateTime.now(),
    expired: j['expired'] == true,
  );
}

/// The saved logins: an index and a sealed payload each.
class SavedLogins {
  SavedLogins(this.store);

  final SealedStore store;

  /// The list, for the Preview's key menu (loaded by [load]).
  final logins = ValueNotifier<List<SavedLogin>>(const []);
  Future<void>? _loading;

  static SavedLogins? _one;

  /// The saved logins kept in [store] (one list per store for the app run).
  static SavedLogins of(SealedStore store) {
    if (_one case final a? when identical(a.store, store)) return a;
    return _one = SavedLogins(store);
  }

  /// The list's file is there but doesn't open (another keychain): nothing is saved over it.
  var unreadable = false;

  /// Reads the list once; a read that fails (no key: a refused keychain prompt) is tried again next time.
  Future<void> load() => _loading ??=
      () async {
        final j = await store.read('logins');
        if (j == null && store.exists('logins')) unreadable = true;
        logins.value = [for (final l in (j is List ? j : const [])) ?_loginFrom(l)];
      }().catchError((Object e) {
        _loading = null;
        throw e;
      });

  Future<void> _saveIndex() async {
    if (unreadable) {
      throw StateError(
        "The saved logins can't be opened with this computer's keychain, so nothing was saved over them.",
      );
    }
    await _writeIndex();
  }

  Future<void> _writeIndex() => store.write('logins', [for (final l in logins.value) _loginJson(l)]);

  /// The logins session of project [projectId] may use for [site] (null: every site), the project's first.
  List<SavedLogin> usable(String? projectId, {String? site}) => [
    for (final l in logins.value)
      if ((site == null || l.site == site) && (l.scope == LoginScope.global || l.projectId == projectId)) l,
  ]..sort((a, b) => (a.scope == LoginScope.project ? 0 : 1).compareTo(b.scope == LoginScope.project ? 0 : 1));

  /// Saves [data] as [site]'s login for [scope]: over the one already there for that site and scope.
  Future<SavedLogin> save(String site, JarData data, {required LoginScope scope, String? projectId}) async {
    await load();
    if (unreadable) await _saveIndex();
    final old = logins.value
        .where((l) => l.site == site && l.scope == scope && (scope == LoginScope.global || l.projectId == projectId))
        .firstOrNull;
    final l = (
      id: old?.id ?? _newId(),
      site: site,
      scope: scope,
      projectId: scope == LoginScope.project ? projectId : null,
      saved: DateTime.now(),
      expired: false,
    );
    await store.write('login-${l.id}', jarToJson(data));
    logins.value = [
      for (final x in logins.value)
        if (x.id != l.id) x,
      l,
    ];
    await _saveIndex();
    return l;
  }

  /// A login's cookies and storage, or null when it's gone.
  Future<JarData?> payload(String id) async {
    final j = await store.read('login-$id');
    return j == null ? null : jarFromJson(j);
  }

  /// A session that started from login [id] ended still signed in: its refreshed sign-in replaces the saved one.
  /// [renewed]: the user signed in again this session (past a login wall), so an expired login works again; without
  /// it the login keeps its expiry.
  Future<void> writeBack(String id, JarData data, {bool renewed = false}) async {
    await load();
    final l = logins.value.where((x) => x.id == id).firstOrNull;
    if (l == null || data.cookies.isEmpty) return;
    await store.write('login-$id', jarToJson(data));
    logins.value = [
      for (final x in logins.value)
        x.id == id
            ? (
                id: x.id,
                site: x.site,
                scope: x.scope,
                projectId: x.projectId,
                saved: DateTime.now(),
                expired: x.expired && !renewed,
              )
            : x,
    ];
    await _saveIndex();
  }

  /// The site asked to sign in again although the session started from login [id].
  Future<void> markExpired(String id) async {
    await load();
    if (!logins.value.any((x) => x.id == id && !x.expired)) return;
    logins.value = [
      for (final x in logins.value)
        x.id == id
            ? (id: x.id, site: x.site, scope: x.scope, projectId: x.projectId, saved: x.saved, expired: true)
            : x,
    ];
    await _saveIndex();
  }

  Future<void> delete(String id) async {
    await load();
    logins.value = [
      for (final x in logins.value)
        if (x.id != id) x,
    ];
    await store.delete('login-$id');
    await _saveIndex();
  }

  /// Project [projectId] was removed: its own saved logins go (those for every project stay).
  Future<void> forgetProject(String projectId) async {
    await load();
    final gone = [
      for (final l in logins.value)
        if (l.scope == LoginScope.project && l.projectId == projectId) l.id,
    ];
    if (gone.isEmpty) return;
    logins.value = [
      for (final x in logins.value)
        if (!gone.contains(x.id)) x,
    ];
    for (final id in gone) {
      await store.delete('login-$id');
    }
    await _saveIndex();
  }

  static String _newId() {
    final r = Random.secure();
    return List.generate(12, (_) => r.nextInt(36).toRadixString(36)).join();
  }
}
