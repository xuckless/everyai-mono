// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../harness/everyai/scrub.dart' show Scrubber;
import 'browser_jar.dart' show LoginScope, SealedStore;
import 'login_import.dart';
import 'login_wall.dart' show siteOf;
import 'totp.dart';

// Logins the user saved for agents (Settings > Code > Logins): a name, a site, a username, a password and maybe an
// authenticator secret. The agent lists them by name and asks the browser or app tool to fill one; the tool types the
// value, which never appears in a result, a log or the transcript. Not the Preview's saved logins (SavedLogins, which
// are cookie jars): these are what a person types.
//
// The user's four switches (LoginPolicy, all on by default) decide how far agents may go.

/// One saved login. Its password and authenticator secret are sealed apart ([AgentLogins.secretsOf]) and never held
/// here.
@immutable
final class LoginEntry {
  const LoginEntry({
    required this.id,
    required this.name,
    required this.site,
    required this.url,
    required this.username,
    required this.scope,
    this.projectId,
    this.agentsCanUse = true,
    this.hasCode = false,
    required this.saved,
  });

  final String id;

  /// What the agent calls it: unique, lower-case, no spaces ("github", "staging-admin").
  final String name;

  /// The site it signs in to ("github.com"; "localhost" for a local app), from [url].
  final String site;

  /// The address it was saved with, as the user gave it.
  final String url;
  final String username;
  final LoginScope scope;
  final String? projectId;

  /// The user's per-login switch: off, agents don't see it.
  final bool agentsCanUse;

  /// It holds an authenticator secret (the fill action can type the current code).
  final bool hasCode;
  final DateTime saved;

  LoginEntry copyWith({bool? agentsCanUse}) => LoginEntry(
    id: id,
    name: name,
    site: site,
    url: url,
    username: username,
    scope: scope,
    projectId: projectId,
    agentsCanUse: agentsCanUse ?? this.agentsCanUse,
    hasCode: hasCode,
    saved: saved,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'site': site,
    'url': url,
    'username': username,
    'scope': scope.name,
    'project': projectId,
    'agents': agentsCanUse,
    'code': hasCode,
    'saved': saved.toIso8601String(),
  };

  static LoginEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'], site = j['site'];
    if (id is! String || name is! String || site is! String) return null;
    return LoginEntry(
      id: id,
      name: name,
      site: site,
      url: '${j['url'] ?? site}',
      username: '${j['username'] ?? ''}',
      scope: j['scope'] == 'project' ? LoginScope.project : LoginScope.global,
      projectId: j['project'] as String?,
      agentsCanUse: j['agents'] != false,
      hasCode: j['code'] == true,
      saved: DateTime.tryParse('${j['saved']}') ?? DateTime.now(),
    );
  }
}

/// Which value a fill types.
enum LoginField {
  username,
  password,
  code;

  static LoginField? parse(Object? v) => values.where((f) => f.name == '$v'.trim().toLowerCase()).firstOrNull;
}

/// The user's four switches for agents and logins (Settings > Code > Logins), all on unless turned off. Read once
/// where a tool runs and passed down; nothing reads Preferences deeper in.
@immutable
final class LoginPolicy {
  const LoginPolicy({this.withoutAsking = true, this.secretFields = true, this.codes = true, this.anySite = true});

  /// Agents use logins without asking. Off: the first use of each login in a session waits for Allow on a card.
  final bool withoutAsking;

  /// Agents may type into password, one-time code and payment fields (and submit their forms) with the ordinary
  /// type, press and click actions. Off: only fill_login reaches them.
  final bool secretFields;

  /// Logins may hold an authenticator secret, and fill_login types its current code.
  final bool codes;

  /// A login fills on any site. Off: only on its own site and its subdomains.
  final bool anySite;

  /// Everything on (the default).
  static const open = LoginPolicy();

  static const prefWithoutAsking = 'code.logins.without_asking';
  static const prefSecretFields = 'code.logins.secret_fields';
  static const prefCodes = 'code.logins.codes';
  static const prefAnySite = 'code.logins.any_site';

  /// From the app's preferences ([pref] reads a key): '0' is off, anything else (or nothing) on.
  factory LoginPolicy.read(String? Function(String key) pref) => LoginPolicy(
    withoutAsking: pref(prefWithoutAsking) != '0',
    secretFields: pref(prefSecretFields) != '0',
    codes: pref(prefCodes) != '0',
    anySite: pref(prefAnySite) != '0',
  );

  @override
  bool operator ==(Object other) =>
      other is LoginPolicy &&
      other.withoutAsking == withoutAsking &&
      other.secretFields == secretFields &&
      other.codes == codes &&
      other.anySite == anySite;

  @override
  int get hashCode => Object.hash(withoutAsking, secretFields, codes, anySite);
}

/// [text] as a login name: lower-case letters, digits, '.', '_' and '-' ("GitHub (work)" → "github-work").
String loginSlug(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
    .replaceAll(RegExp(r'-{2,}'), '-')
    .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');

/// The site [url] signs in to ("github.com" for https://gist.github.com/login), or '' when it has no host.
String loginSiteOf(String url) {
  final u = url.trim();
  if (u.isEmpty) return '';
  final uri = Uri.tryParse(RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false).hasMatch(u) ? u : 'https://$u');
  final host = uri?.host ?? '';
  return host.isEmpty ? '' : siteOf(host);
}

/// Whether a login for [site] belongs on a page at [pageHost]: the site itself or one of its subdomains.
bool loginFitsHost(String site, String pageHost) {
  final h = pageHost.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  final s = site.toLowerCase();
  if (h.isEmpty || s.isEmpty) return false;
  return h == s || h.endsWith('.$s');
}

/// Why login [e]'s [field] may not be filled on the page at [pageUrl] (null: no page, an app screen) under [policy];
/// null when it may. The consent card ([LoginGate]) comes after this.
String? fillRefusal(LoginEntry e, LoginField field, {required LoginPolicy policy, String? pageUrl}) {
  if (!e.agentsCanUse) {
    return "The user turned off '${e.name}' for agents (Settings > Code > Logins).";
  }
  if (field == LoginField.code) {
    if (!policy.codes) {
      return 'The user keeps authenticator codes out of EveryAI (Settings > Code > Logins), so the user types the code: '
          'ask them.';
    }
    if (!e.hasCode) {
      return "'${e.name}' has no authenticator secret. A code from an authenticator app, a text message or an email "
          'needs the user: ask them for it.';
    }
  }
  if (field == LoginField.username && e.username.isEmpty) return "'${e.name}' has no username saved.";
  if (pageUrl != null && !policy.anySite) {
    final host = Uri.tryParse(pageUrl)?.host ?? '';
    if (!loginFitsHost(e.site, host)) {
      return "'${e.name}' is for ${e.site}, and this page is on ${host.isEmpty ? 'no site' : host}. The user lets "
          'logins fill only on their own site (Settings > Code > Logins).';
    }
  }
  return null;
}

/// What the agent reads about [logins] ([pageHost]: the page's host, to mark the ones that fit it).
String loginsListText(List<LoginEntry> logins, {String? pageHost, required LoginPolicy policy}) {
  if (logins.isEmpty) {
    return 'No saved logins for this project. The user adds them in Settings > Code > Logins; ask them if you need '
        'to sign in.';
  }
  final lines = [
    'Saved logins (values stay hidden; fill_login {login, field: "username" | "password"${policy.codes ? ' | "code"' : ''}, '
        'ref or selector, submit?} types them):',
    for (final l in logins)
      '- ${l.name} · ${l.site}${l.username.isEmpty ? '' : ' · user ${l.username}'}'
          '${l.hasCode && policy.codes ? ' · authenticator code' : ''}'
          '${pageHost != null && loginFitsHost(l.site, pageHost) ? '  [fits this page]' : ''}',
    if (!policy.anySite) 'A login fills only on its own site and its subdomains.',
    if (!policy.withoutAsking) 'The user is asked once per login and session before the first fill.',
    'A one-time code sent by text message or email still needs the user.',
  ];
  return lines.join('\n');
}

/// What a fill result says: never the value.
String filledText(LoginEntry e, LoginField field, {String? into, bool submitted = false}) {
  final what = switch (field) {
    LoginField.username => 'the username',
    LoginField.password => 'the password',
    LoginField.code => 'the current authenticator code',
  };
  return "Filled $what of '${e.name}'${into == null ? ' into the focused field' : ' into $into'}"
      '${submitted ? ' and pressed Enter' : ''}.';
}

/// The secrets of one login.
typedef LoginSecrets = ({String password, String? totp});

/// Thrown when a login can't be saved (a name taken, no address, an authenticator secret that isn't one).
final class LoginSaveError implements Exception {
  const LoginSaveError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The logins the user saved for agents: an index (no secrets) and a sealed file of secrets per login.
class AgentLogins {
  AgentLogins(this.store);

  final SealedStore store;

  /// The list, for Settings and the tools (loaded by [load]).
  final entries = ValueNotifier<List<LoginEntry>>(const []);
  Future<void>? _loading;

  /// The list's file is there but doesn't open (another keychain): nothing is saved over it.
  var unreadable = false;

  static AgentLogins? _one;

  /// The logins kept in [store] (one list per store for the app run).
  static AgentLogins of(SealedStore store) {
    if (_one case final a? when identical(a.store, store)) return a;
    return _one = AgentLogins(store);
  }

  // ------------------------------------------------------------------------- where the app plugs in (app start)

  /// The sealed store (the app's, with a keychain key); unset in tests: no logins.
  static Future<SealedStore> Function()? sealed;

  /// The user's switches now (from Preferences); unset: [LoginPolicy.open].
  static LoginPolicy Function()? readPolicy;

  /// The project of Code session [sessionId], for project logins.
  static String? Function(String sessionId)? projectOf;

  /// The app's logins, loaded; null when there is no store (tests) or it can't be opened.
  static Future<AgentLogins?> app() async {
    final s = sealed;
    if (s == null) return null;
    try {
      final l = AgentLogins.of(await s());
      await l.load();
      return l;
    } on Object {
      return null;
    }
  }

  /// What a tool call for session [sessionId] may do with logins: the switches now, the session's project and
  /// consent gate. [hide] gets each value typed (the session's scrubber); [askFor]: how long a consent card waits.
  static LoginAccess accessFor(
    String sessionId, {
    void Function(String secret)? hide,
    Duration askFor = const Duration(minutes: 10),
  }) => LoginAccess(
    policy: readPolicy?.call() ?? LoginPolicy.open,
    projectId: projectOf?.call(sessionId),
    logins: app,
    gate: LoginGate.of(sessionId),
    hide: hide,
    askFor: askFor,
  );

  // ------------------------------------------------------------------------------------------------- the list

  /// Reads the list once; a read that fails (no key: a refused keychain prompt) is tried again next time.
  Future<void> load() => _loading ??=
      () async {
        final j = await store.read('agent-logins');
        if (j == null && store.exists('agent-logins')) unreadable = true;
        entries.value = [for (final l in (j is List ? j : const [])) ?LoginEntry.fromJson(l)];
      }().catchError((Object e) {
        _loading = null;
        throw e;
      });

  Future<void> _saveIndex() async {
    if (unreadable) {
      throw const LoginSaveError(
        "The saved logins can't be opened with this computer's keychain, so nothing was saved.",
      );
    }
    await store.write('agent-logins', [for (final l in entries.value) l.toJson()]);
  }

  /// The logins a session of project [projectId] may fill: switched on for agents, for every project or this one;
  /// the project's first.
  List<LoginEntry> usable(String? projectId) => [
    for (final l in entries.value)
      if (l.agentsCanUse && (l.scope == LoginScope.global || l.projectId == projectId)) l,
  ]..sort((a, b) => (a.scope == LoginScope.project ? 0 : 1).compareTo(b.scope == LoginScope.project ? 0 : 1));

  /// The usable login called [name] (any case), or null.
  LoginEntry? named(String name, String? projectId) {
    final n = name.trim().toLowerCase();
    return usable(projectId).where((l) => l.name == n).firstOrNull;
  }

  /// [base] as a name no other login (but [except]) has: "github", "github-2", …
  String freeName(String base, {String? except}) {
    final b = loginSlug(base).isEmpty ? 'login' : loginSlug(base);
    bool taken(String n) => entries.value.any((l) => l.name == n && l.id != except);
    if (!taken(b)) return b;
    for (var i = 2; ; i++) {
      if (!taken('$b-$i')) return '$b-$i';
    }
  }

  /// Saves a login (a new one, or [id]'s). [password] null keeps the saved one (an edit); [totp] null keeps the saved
  /// authenticator secret, '' removes it. Throws [LoginSaveError] when it can't.
  Future<LoginEntry> save({
    String? id,
    required String name,
    required String url,
    required String username,
    String? password,
    String? totp,
    required LoginScope scope,
    String? projectId,
    bool agentsCanUse = true,
  }) async {
    await load();
    final slug = loginSlug(name);
    if (slug.isEmpty) throw const LoginSaveError('Give the login a name.');
    if (entries.value.any((l) => l.name == slug && l.id != id)) {
      throw LoginSaveError('Another login is already called "$slug".');
    }
    final site = loginSiteOf(url);
    if (site.isEmpty) throw const LoginSaveError('Give the address of the site it signs in to.');
    if (scope == LoginScope.project && projectId == null) throw const LoginSaveError('Pick a project.');
    final old = id == null ? null : entries.value.where((l) => l.id == id).firstOrNull;
    final oldSecrets = old == null ? null : await secretsOf(old.id);
    final pw = password ?? oldSecrets?.password;
    if (pw == null || pw.isEmpty) throw const LoginSaveError('Give the password.');
    final code = totp == null ? oldSecrets?.totp : (totp.trim().isEmpty ? null : totp.trim());
    if (code != null && parseTotp(code) == null) {
      throw const LoginSaveError(
        "That authenticator secret isn't one: paste the setup key (letters A-Z and digits 2-7) or the otpauth:// "
        'address.',
      );
    }
    final e = LoginEntry(
      id: old?.id ?? _newId(),
      name: slug,
      site: site,
      url: url.trim(),
      username: username.trim(),
      scope: scope,
      projectId: scope == LoginScope.project ? projectId : null,
      agentsCanUse: agentsCanUse,
      hasCode: code != null,
      saved: DateTime.now(),
    );
    await store.write('agent-login-${e.id}', {'password': pw, 'totp': ?code});
    // A renamed login is a new one to sessions that answered about the old name.
    if (old != null && old.name != e.name) LoginGate.revokeEverywhere(old.name);
    entries.value = [
      for (final x in entries.value)
        if (x.id != e.id) x,
      e,
    ];
    await _saveIndex();
    return e;
  }

  /// Login [id]'s password and authenticator secret, or null when it's gone.
  Future<LoginSecrets?> secretsOf(String id) async {
    final j = await store.read('agent-login-$id');
    if (j is! Map || j['password'] is! String) return null;
    return (password: j['password'] as String, totp: j['totp'] as String?);
  }

  /// The per-login "Agents can use" switch.
  Future<void> setAgentsCanUse(String id, bool on) async {
    await load();
    entries.value = [for (final x in entries.value) x.id == id ? x.copyWith(agentsCanUse: on) : x];
    await _saveIndex();
  }

  /// Deletes login [id] with its password and authenticator secret; sessions that were allowed to use it ask again.
  Future<void> delete(String id) async {
    await load();
    final gone = entries.value.where((x) => x.id == id).firstOrNull;
    if (gone != null) LoginGate.revokeEverywhere(gone.name);
    entries.value = [
      for (final x in entries.value)
        if (x.id != id) x,
    ];
    await store.delete('agent-login-$id');
    await _saveIndex();
  }

  /// Deletes every login (and every approval of them).
  Future<void> deleteAll() async {
    await load();
    final ids = [for (final l in entries.value) l.id];
    entries.value = const [];
    LoginGate.revokeAll();
    for (final id in ids) {
      await store.delete('agent-login-$id');
    }
    await _saveIndex();
  }

  /// Project [projectId] was removed: its own logins go (those for every project stay).
  Future<void> forgetProject(String projectId) async {
    await load();
    final gone = [
      for (final l in entries.value)
        if (l.scope == LoginScope.project && l.projectId == projectId) l.id,
    ];
    if (gone.isEmpty) return;
    entries.value = [
      for (final x in entries.value)
        if (!gone.contains(x.id)) x,
    ];
    for (final id in gone) {
      await store.delete('agent-login-$id');
    }
    await _saveIndex();
  }

  /// Saves [rows] from a password manager's export for [scope]; their authenticator secrets only with [codes]. A row
  /// whose site and username are already saved is left out. How many were added and left out.
  Future<({int added, int skipped})> importAll(
    List<ImportedLogin> rows, {
    required LoginScope scope,
    String? projectId,
    required bool codes,
  }) async {
    await load();
    var added = 0, skipped = 0;
    for (final r in rows) {
      final site = loginSiteOf(r.url);
      if (site.isEmpty || entries.value.any((l) => l.site == site && l.username == r.username.trim())) {
        skipped++;
        continue;
      }
      final totp = codes && r.totp != null && parseTotp(r.totp!) != null ? r.totp : null;
      try {
        await save(
          name: freeName(r.title.isEmpty ? site.split('.').first : r.title),
          url: r.url,
          username: r.username,
          password: r.password,
          totp: totp,
          scope: scope,
          projectId: projectId,
        );
        added++;
      } on LoginSaveError {
        skipped++;
      }
    }
    return (added: added, skipped: skipped);
  }

  static String _newId() {
    final r = Random.secure();
    return List.generate(12, (_) => r.nextInt(36).toRadixString(36)).join();
  }
}

/// What one tool call may do with logins: the user's switches, the session's project, its store and consent gate.
@immutable
final class LoginAccess {
  const LoginAccess({
    this.policy = LoginPolicy.open,
    this.projectId,
    this.logins,
    this.gate,
    this.hide,
    this.askFor = const Duration(minutes: 10),
  });

  final LoginPolicy policy;
  final String? projectId;

  /// The logins (null: none here).
  final Future<AgentLogins?> Function()? logins;

  /// The session's consent gate; null: never asks (a rig).
  final LoginGate? gate;

  /// Hides a value typed in the session's scrubber.
  final void Function(String secret)? hide;
  final Duration askFor;

  /// The usable logins of the project.
  Future<List<LoginEntry>> usable() async => (await logins?.call())?.usable(projectId) ?? const [];

  /// [text] with every value filled this session hidden.
  String redact(String text) => gate?.redact(text) ?? text;

  /// The value of [field] of [e] to type, after the checks: hidden in the session first. Throws a [StateError] with
  /// the agent's message when it can't be had.
  Future<String> valueOf(LoginEntry e, LoginField field) async {
    if (field == LoginField.username) return e.username;
    final store = await logins?.call();
    final s = store == null ? null : await store.secretsOf(e.id);
    if (s == null) throw StateError("'${e.name}' can't be read now (it was removed, or the keychain refused).");
    final String value;
    if (field == LoginField.password) {
      value = s.password;
    } else {
      final spec = s.totp == null ? null : parseTotp(s.totp!);
      if (spec == null) throw StateError("'${e.name}' has no usable authenticator secret.");
      // A code about to change is typed after it has: a page may take a second to check it.
      if (totpSecondsLeft(spec) <= 2) await Future<void>.delayed(Duration(seconds: totpSecondsLeft(spec)));
      // A code is good for seconds and is a plain number: it isn't hidden in later output (that would garble
      // numbers there), only kept out of this call's result.
      return totpCode(spec);
    }
    gate?.remember(value);
    hide?.call(value);
    return value;
  }

  /// Waits for the user's Allow when the switches say to ask; null when it may go on, else the agent's message.
  Future<String?> consent(LoginEntry e) async {
    final g = gate;
    if (policy.withoutAsking || g == null) return null;
    return switch (await g.ensure(e.name, site: e.site, timeout: askFor)) {
      ConsentOutcome.allowed => null,
      ConsentOutcome.denied =>
        "The user said no to using '${e.name}' in this session. Work without it, or ask them what to do.",
      ConsentOutcome.timedOut =>
        "The user hasn't answered whether you may use '${e.name}' (a card above their composer asks). Do other work "
            'and try again later.',
      ConsentOutcome.stopped => "The wait for the user's answer about '${e.name}' ended: the session stopped.",
    };
  }
}

// ------------------------------------------------------------------------------------------- asking first

/// How a wait for the user's answer about a login ended.
enum ConsentOutcome { allowed, denied, timedOut, stopped }

/// Where one login stands in one session when the user wants to be asked first:
///
///   unasked ──first fill──▶ asking ──Allow──▶ allowed ──Stop allowing──▶ unasked
///                              │ ──Deny───▶ denied  ──forget──────────▶ unasked
///                              └ ──time limit / Stop──▶ unasked (asked again next time)
///
/// Answers last for the session (nothing is remembered across sessions).
sealed class LoginConsent {
  const LoginConsent();
}

final class ConsentUnasked extends LoginConsent {
  const ConsentUnasked();
}

/// The card is up; every fill of this login waits on [answer].
final class ConsentAsking extends LoginConsent {
  ConsentAsking(this.site);
  final String site;
  final answer = Completer<ConsentOutcome>();
}

final class ConsentAllowed extends LoginConsent {
  const ConsentAllowed();
}

final class ConsentDenied extends LoginConsent {
  const ConsentDenied();
}

/// A card's question: may the agent of [gate]'s session use [login] (on [site])?
typedef LoginAsk = ({LoginGate gate, String login, String site});

/// One Code session's answers about logins, and the values it has filled (hidden in what its tools return).
final class LoginGate {
  LoginGate._(this.session);

  final String session;

  static final _bySession = <String, LoginGate>{};

  /// Session [session]'s gate (made on first use).
  static LoginGate of(String session) => _bySession[session] ??= LoginGate._(session);

  /// Session [session]'s gate if it has one.
  static LoginGate? find(String session) => _bySession[session];

  /// Session [session] was removed.
  static void forget(String session) => _bySession.remove(session)?.stop();

  /// Every open question, for the cards above the composer and on the Board.
  static final asks = ValueNotifier<List<LoginAsk>>(const []);

  /// Goes up whenever an answer changes anywhere (Settings' list of approvals follows it).
  static final changes = ValueNotifier<int>(0);

  /// Every session's gate this run.
  static Iterable<LoginGate> get all => _bySession.values;

  /// Every answer given this run: which login, in which session, allowed or denied.
  static List<({LoginGate gate, String login, bool allowed})> get answered => [
    for (final g in _bySession.values)
      for (final MapEntry(key: login, value: s) in g._states.entries)
        if (s is ConsentAllowed || s is ConsentDenied) (gate: g, login: login, allowed: s is ConsentAllowed),
  ];

  /// Login [login] was deleted or renamed: every session asks about it again.
  static void revokeEverywhere(String login) {
    for (final g in _bySession.values) {
      g.revoke(login);
    }
  }

  /// Forget all approvals (and refusals) in every session.
  static void revokeAll() {
    for (final g in _bySession.values) {
      for (final login in [...g._states.keys]) {
        g.revoke(login);
      }
    }
  }

  /// The logins allowed in this session.
  List<String> get allowed => [
    for (final MapEntry(key: login, value: s) in _states.entries)
      if (s is ConsentAllowed) login,
  ];

  /// Stop allowing (or forget a refusal of) [login] here: the next fill asks again. An open question stays.
  void revoke(String login) {
    final s = _states[login];
    if (s is! ConsentAllowed && s is! ConsentDenied) return;
    _states.remove(login);
    changes.value++;
  }

  final _states = <String, LoginConsent>{};

  LoginConsent stateOf(String login) => _states[login] ?? const ConsentUnasked();

  /// Waits until the user allows or denies [login] for this session (at once when they already did), [timeout]
  /// passes, or the session stops.
  Future<ConsentOutcome> ensure(String login, {required String site, Duration timeout = const Duration(minutes: 10)}) {
    switch (stateOf(login)) {
      case ConsentAllowed():
        return Future.value(ConsentOutcome.allowed);
      case ConsentDenied():
        return Future.value(ConsentOutcome.denied);
      case final ConsentAsking a:
        return a.answer.future;
      case ConsentUnasked():
        final a = ConsentAsking(site);
        _states[login] = a;
        asks.value = [...asks.value, (gate: this, login: login, site: site)];
        changes.value++;
        final timer = Timer(timeout, () => _settle(login, ConsentOutcome.timedOut));
        unawaited(a.answer.future.whenComplete(timer.cancel));
        return a.answer.future;
    }
  }

  /// The user's answer on the card.
  void answer(String login, {required bool allow}) =>
      _settle(login, allow ? ConsentOutcome.allowed : ConsentOutcome.denied);

  /// The session stopped: open questions end (asked again next time).
  void stop() {
    for (final login in [..._states.keys]) {
      if (_states[login] is ConsentAsking) _settle(login, ConsentOutcome.stopped);
    }
  }

  void _settle(String login, ConsentOutcome outcome) {
    final s = _states[login];
    if (s is! ConsentAsking) return;
    _states[login] = switch (outcome) {
      ConsentOutcome.allowed => const ConsentAllowed(),
      ConsentOutcome.denied => const ConsentDenied(),
      ConsentOutcome.timedOut || ConsentOutcome.stopped => const ConsentUnasked(),
    };
    asks.value = [
      for (final a in asks.value)
        if (!(identical(a.gate, this) && a.login == login)) a,
    ];
    changes.value++;
    s.answer.complete(outcome);
  }

  // -------------------------------------------------------------------------------------------- filled values

  final _secrets = <String>{};

  /// A value filled this session: hidden from now on in what the session's tools return.
  void remember(String value) {
    // Very short values would hide ordinary text (a 4-digit PIN is still hidden).
    if (value.length >= 4) _secrets.add(value);
  }

  /// [text] with the values filled this session swapped for a mark.
  String redact(String text) {
    var out = text;
    for (final v in _secrets.toList()..sort((a, b) => b.length - a.length)) {
      if (out.contains(v)) out = out.replaceAll(v, '${Scrubber.hiddenMark} saved login]');
    }
    return out;
  }
}
