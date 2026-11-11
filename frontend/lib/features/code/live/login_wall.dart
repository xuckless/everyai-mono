// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter/foundation.dart';

// The login wall: the agent's browser reached a sign-in page it has no saved login for (with one, the browser tool
// tells the agent to fill it instead: see runBrowser). Signing in is then the user's, so the agent's call waits while
// a card asks the user, and goes on once the page is past the sign-in, or the user says to carry on without it.
//
//   idle ──hold──▶ waiting ──page past the sign-in──▶ idle   (passed)
//                     │ ──Skip──────────────────────▶ idle   (skipped; that site holds no more calls)
//                     │ ──time limit────────────────▶ idle   (timedOut)
//                     └ ──session stopped───────────▶ idle   (stopped)

/// What the page shows, for telling a sign-in page: its address and whether it has a visible password field.
typedef LoginProbe = ({String url, bool password});

/// How a wait at the login wall ended.
enum WallOutcome { passed, skipped, timedOut, stopped }

/// A wall's state: no call waits, or the agent's call waits for the user to sign in to [site].
sealed class WallState {
  const WallState();
}

final class WallIdle extends WallState {
  const WallIdle();
}

final class WallWaiting extends WallState {
  const WallWaiting(this.site, this.url);

  /// The site to sign in to ("github.com") and the sign-in page.
  final String site;
  final String url;
}

/// One session browser's login wall.
final class LoginWall {
  LoginWall();

  /// Every wall whose agent waits, for the cards above the composer and on the Board.
  static final waiting = ValueNotifier<List<LoginWall>>(const []);

  final state = ValueNotifier<WallState>(const WallIdle());

  /// Sites the user said to carry on without (Skip): the agent isn't held on them again this session.
  final _skipped = <String>{};

  Completer<WallOutcome>? _held;

  bool skipped(String site) => _skipped.contains(site);

  /// How the last wait for each site ended this session (none: the site never asked to sign in).
  final _last = <String, WallOutcome>{};

  /// How the last wait at the wall for [site] ended this session, or null when it never asked.
  WallOutcome? lastOutcome(String site) => _last[site];

  /// Holds the agent's call until [probe] shows a page past the sign-in to [site] (checked every [every]), the user
  /// skips, [timeout] passes, or [stop]. One wait at a time: a second call joins the first.
  Future<WallOutcome> hold(
    String site,
    String url, {
    required Future<LoginProbe?> Function() probe,
    Duration timeout = const Duration(minutes: 10),
    Duration every = const Duration(milliseconds: 1500),
  }) {
    if (_held case final h?) return h.future;
    final done = _held = Completer<WallOutcome>();
    state.value = WallWaiting(site, url);
    waiting.value = [...waiting.value, this];
    final deadline = DateTime.now().add(timeout);
    Future<void> poll() async {
      while (!done.isCompleted) {
        await Future<void>.delayed(every);
        if (done.isCompleted) return;
        if (DateTime.now().isAfter(deadline)) return _end(WallOutcome.timedOut);
        final LoginProbe? p;
        try {
          p = await probe();
        } on Object {
          continue;
        }
        if (done.isCompleted) return;
        // Gone from the sign-in (to the site itself, or anywhere else): the user signed in, or went past it.
        if (p != null && loginWallSite(p.url, password: p.password) != site) return _end(WallOutcome.passed);
      }
    }

    unawaited(poll());
    return done.future;
  }

  /// The user's Skip: the agent goes on without signing in.
  void skip() {
    if (state.value case WallWaiting(:final site)) _skipped.add(site);
    _end(WallOutcome.skipped);
  }

  /// The session stopped, or its browser closed: the waiting call ends.
  void stop() => _end(WallOutcome.stopped);

  void _end(WallOutcome outcome) {
    final h = _held;
    if (h == null || h.isCompleted) return;
    _held = null;
    if (state.value case WallWaiting(:final site)) _last[site] = outcome;
    state.value = const WallIdle();
    waiting.value = [
      for (final w in waiting.value)
        if (!identical(w, this)) w,
    ];
    h.complete(outcome);
  }
}

/// What the agent's result says after a wait at the wall for [site].
String wallOutcomeText(String site, WallOutcome outcome) => switch (outcome) {
  WallOutcome.passed => 'The page asked to sign in to $site; the user took care of it and the page went on.',
  WallOutcome.skipped =>
    'The page asks to sign in to $site, and the user chose to carry on without signing in. Work without it, or ask '
        'the user what to do.',
  WallOutcome.timedOut =>
    'The page asks to sign in to $site and nobody has signed in yet. The user was asked (a card above their '
        'composer). Do other work and check again later, or ask them.',
  WallOutcome.stopped => 'The page asks to sign in to $site; the wait ended because the session stopped.',
};

/// Sign-in services whose pages are walls wherever they lead: site (as the card names it) by host.
const _authHosts = {
  'accounts.google.com': 'google.com',
  'login.microsoftonline.com': 'microsoft.com',
  'login.live.com': 'microsoft.com',
  'account.live.com': 'microsoft.com',
  'appleid.apple.com': 'apple.com',
  'idmsa.apple.com': 'apple.com',
  'id.atlassian.com': 'atlassian.com',
  'login.salesforce.com': 'salesforce.com',
  'auth.openai.com': 'openai.com',
};

// Only paths that are a sign-in page: not /auth, /oauth2 or /sessions, which are as often docs or an API. The sign-in
// segment sits near the front ("/login", "/u/login", "/users/sign_in"), and never in docs ("/docs/sso/setup").
final _authSegment = RegExp(r'^(log-?in|sign-?in|sign_in|sso)(\.\w+)?$', caseSensitive: false);
const _docSegments = {
  'docs',
  'doc',
  'documentation',
  'help',
  'blog',
  'guide',
  'guides',
  'learn',
  'support',
  'kb',
  'articles',
  'wiki',
  'reference',
  'manual',
  'tutorial',
  'tutorials',
  'changelog',
  'news',
  'faq',
  'developers',
  'dev-docs',
  'api-docs',
};

bool _authPath(String path) {
  final segments = [
    for (final s in path.split('/'))
      if (s.isNotEmpty) s.toLowerCase(),
  ];
  if (segments.any(_docSegments.contains)) return false;
  for (var i = 0; i < segments.length && i < 3; i++) {
    if (_authSegment.hasMatch(segments[i])) return true;
  }
  return false;
}

/// The site a sign-in page at [url] is for ("github.com"), or null when it isn't one: a page with a visible
/// [password] field, a sign-in service (Google, Microsoft, Apple, Auth0, Okta…), or a sign-in path (/login,
/// /signin, /sso). Never the app the session builds (a local page): its sign-in is tested another way.
String? loginWallSite(String url, {required bool password}) {
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return null;
  final host = uri.host.toLowerCase();
  if (isLocalHost(host) && !wallOnLocalPages) return null;
  if (_authHosts[host] case final site?) return site;
  for (final provider in const ['auth0.com', 'okta.com', 'onelogin.com', 'clerk.accounts.dev']) {
    if (host.endsWith('.$provider')) return host;
  }
  if (password || _authPath(uri.path)) return siteOf(host);
  return null;
}

/// The registrable part of [host] ("github.com" for "gist.github.com", "bbc.co.uk" for "www.bbc.co.uk"): what a
/// sign-in covers. Addresses and single names stay as they are.
String siteOf(String host) {
  final h = host.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
  if (RegExp(r'^[\d.]+$').hasMatch(h) || h.contains(':') || !h.contains('.')) return h;
  final parts = h.split('.');
  // Hosts where each name is someone else's app (x.github.io, my-app.vercel.app): the name is the site.
  for (final shared in _sharedHosts) {
    if (h.endsWith('.$shared')) {
      final n = shared.split('.').length + 1;
      return parts.length <= n ? h : parts.sublist(parts.length - n).join('.');
    }
  }
  if (parts.length <= 2) return h;
  final second = parts[parts.length - 2];
  final countryPair =
      parts.last.length == 2 && const {'co', 'com', 'org', 'net', 'ac', 'gov', 'edu', 'ne', 'or'}.contains(second);
  return parts.sublist(parts.length - (countryPair ? 3 : 2)).join('.');
}

const _sharedHosts = [
  'github.io',
  'gitlab.io',
  'vercel.app',
  'netlify.app',
  'pages.dev',
  'workers.dev',
  'herokuapp.com',
  'web.app',
  'firebaseapp.com',
  'appspot.com',
  'azurewebsites.net',
  'azurestaticapps.net',
  'cloudfront.net',
  'onrender.com',
  'fly.dev',
  'railway.app',
  'replit.app',
  'glitch.me',
  'ngrok.io',
  'ngrok-free.app',
  'trycloudflare.com',
  'blogspot.com',
  'myshopify.com',
  's3.amazonaws.com',
  'supabase.co',
];

/// Tests: a local page stands in for a site.
@visibleForTesting
var wallOnLocalPages = false;

/// Whether [host] is this computer or the local network (the app the session builds, a dev box): loopback, private
/// and link-local addresses, and local-only names (.localhost, .local, .test).
bool isLocalHost(String host) {
  var h = host.toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  if (h == 'localhost' || h == '0.0.0.0' || h == '::1' || h == '::') return true;
  for (final suffix in const ['.localhost', '.local', '.test']) {
    if (h.endsWith(suffix)) return true;
  }
  final v4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(h);
  if (v4 != null) {
    final a = int.parse(v4[1]!), b = int.parse(v4[2]!);
    return a == 127 || a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 169 && b == 254);
  }
  if (h.contains(':')) {
    // fc00::/7 (unique local) and fe80::/10 (link-local).
    return RegExp(r'^f[cd][0-9a-f]{0,2}:').hasMatch(h) || RegExp(r'^fe[89ab][0-9a-f]?:').hasMatch(h);
  }
  return false;
}
