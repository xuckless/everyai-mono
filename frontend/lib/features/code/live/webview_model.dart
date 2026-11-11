// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'key_map.dart';

// The pure parts of the OS webview backend ([WebviewBrowser] in webview_browser.dart): its lifecycle and each tab's,
// cookies to and from the session's jar, what a key press does by default, and the user agent.

/// Where a session's webview browser is.
///
/// ```text
///   notCreated ──use──▶ starting ──first tab up──▶ running(headless | shown) ──close / last tab──▶ closing ──▶ closed
///                          │ fail / close                 ▲   show / hide   │                                  │
///                          └──────────────▶ closing       └─────────────────┘            closed ──use──▶ starting
/// ```
/// Every start takes a new generation: a start that lands under another one was closed meanwhile.
sealed class WebviewLife {
  const WebviewLife();
}

final class WebviewNotCreated extends WebviewLife {
  const WebviewNotCreated();
}

final class WebviewStarting extends WebviewLife {
  const WebviewStarting(this.generation, this.ready);
  final int generation;
  final Future<void> ready;
}

final class WebviewRunning extends WebviewLife {
  const WebviewRunning(this.generation, {required this.shown});
  final int generation;

  /// The active tab is in the Preview (else every tab runs offscreen).
  final bool shown;
}

final class WebviewClosing extends WebviewLife {
  const WebviewClosing(this.done);
  final Future<void> done;
}

final class WebviewClosed extends WebviewLife {
  const WebviewClosed();
}

/// Whether the browser may move from [from] to [to].
bool webviewEdge(WebviewLife from, WebviewLife to) => switch ((from, to)) {
  (WebviewNotCreated() || WebviewClosed(), WebviewStarting()) => true,
  (WebviewStarting(), WebviewRunning() || WebviewClosing() || WebviewClosed()) => true,
  (WebviewRunning(), WebviewRunning() || WebviewClosing()) => true,
  (WebviewClosing(), WebviewClosed()) => true,
  _ => false,
};

/// Where one tab's native webview is.
///
/// ```text
///   starting ──created──▶ headless ──Preview shows it──▶ shown ──Preview hides it──▶ parking ──back in the window──▶ parked
///                                                          ▲                                                       │
///                                                          └────────────────────── Preview shows it ───────────────┘
///   (any) ──close──▶ closed
/// ```
/// A tab hidden by the Preview is still being taken out of its view while parking; it is shown again only once
/// parked, so the platform view isn't handed over twice in one frame.
enum TabLife {
  /// The plugin is making its webview.
  starting,

  /// Running offscreen (the plugin's headless webview, kept in the app's window so it stays live).
  headless,

  /// In the Preview.
  shown,

  /// The Preview let go of it; it is going back into the app's window offscreen.
  parking,

  /// Offscreen again, live.
  parked,

  closed;

  /// Whether a tab may move from this state to [to].
  bool canMoveTo(TabLife to) => switch ((this, to)) {
    (_, TabLife.closed) => this != TabLife.closed,
    (TabLife.starting, TabLife.headless) => true,
    (TabLife.headless || TabLife.parked, TabLife.shown) => true,
    (TabLife.shown, TabLife.parking) => true,
    (TabLife.parking, TabLife.parked) => true,
    _ => false,
  };

  /// Whether the Preview may put the tab's view on screen now.
  bool get showable => this == TabLife.headless || this == TabLife.parked || this == TabLife.shown;

  /// Whether calls reach the page.
  bool get live => this != TabLife.starting && this != TabLife.closed;
}

/// A cookie as the native side reports and takes it (WKHTTPCookieStore or the plugin's CookieManager).
typedef NativeCookie = ({
  String name,
  String value,
  String domain,
  String path,

  /// Milliseconds since the epoch; null for a session cookie.
  int? expiresMs,
  bool secure,
  bool httpOnly,

  /// `Lax`, `Strict`, `None`, or null.
  String? sameSite,
});

/// [c] as the jar keeps cookies (the DevTools shape `Storage.getCookies` gives).
Map<String, Object?> jarCookieOf(NativeCookie c) => {
  'name': c.name,
  'value': c.value,
  'domain': c.domain,
  'path': c.path.isEmpty ? '/' : c.path,
  'expires': c.expiresMs == null ? -1 : c.expiresMs! / 1000,
  'size': c.name.length + c.value.length,
  'httpOnly': c.httpOnly,
  'secure': c.secure,
  'session': c.expiresMs == null,
  'sameSite': ?_sameSite(c.sameSite),
};

/// The jar's [cookie] for the native store; null when it expired (or has no name).
NativeCookie? nativeCookieOf(Map<String, Object?> cookie, {DateTime? now}) {
  final name = cookie['name'];
  final domain = cookie['domain'];
  if (name is! String || name.isEmpty || domain is! String || domain.isEmpty) return null;
  final expires = (cookie['expires'] as num?)?.toDouble() ?? -1;
  final session = cookie['session'] == true || expires <= 0;
  final at = (now ?? DateTime.now()).millisecondsSinceEpoch / 1000;
  if (!session && expires < at) return null;
  return (
    name: name,
    value: '${cookie['value'] ?? ''}',
    domain: domain,
    path: '${cookie['path'] ?? '/'}',
    expiresMs: session ? null : (expires * 1000).round(),
    secure: cookie['secure'] == true,
    httpOnly: cookie['httpOnly'] == true,
    sameSite: _sameSite(cookie['sameSite'] as String?),
  );
}

String? _sameSite(String? s) => switch (s?.toLowerCase()) {
  'lax' => 'Lax',
  'strict' => 'Strict',
  'none' => 'None',
  _ => null,
};

/// [c] from the map the macOS bridge sends.
NativeCookie? nativeCookieFromMap(Map<Object?, Object?> m) {
  final name = m['name'], domain = m['domain'];
  if (name is! String || domain is! String) return null;
  return (
    name: name,
    value: '${m['value'] ?? ''}',
    domain: domain,
    path: '${m['path'] ?? '/'}',
    expiresMs: (m['expiresMs'] as num?)?.toInt(),
    secure: m['secure'] == true,
    httpOnly: m['httpOnly'] == true,
    sameSite: _sameSite(m['sameSite'] as String?),
  );
}

/// [c] as the macOS bridge takes it.
Map<String, Object?> nativeCookieToMap(NativeCookie c) => {
  'name': c.name,
  'value': c.value,
  'domain': c.domain,
  'path': c.path,
  'expiresMs': c.expiresMs,
  'secure': c.secure,
  'httpOnly': c.httpOnly,
  'sameSite': c.sameSite,
};

/// Whether a request to [url] carries cookie [c] (domain, path and secure match; for our own downloads).
bool cookieMatches(NativeCookie c, Uri url) {
  final host = url.host.toLowerCase();
  final d = c.domain.toLowerCase();
  final domainOk = d.startsWith('.') ? (host == d.substring(1) || host.endsWith(d)) : host == d;
  if (!domainOk) return false;
  if (c.secure && url.scheme != 'https') return false;
  final path = url.path.isEmpty ? '/' : url.path;
  final p = c.path.isEmpty ? '/' : c.path;
  return path == p || path.startsWith(p.endsWith('/') ? p : '$p/');
}

/// What a page does by default with a key press nobody prevented: the emulated part of [WebviewBrowser.press]
/// (script events don't run a browser's own key handling).
enum KeyDefault {
  none,

  /// The key's character goes into the focused field.
  insertText,

  /// Submits the field's form, adds a line in a text area, or presses a focused button or link.
  enter,
  focusNext,
  focusPrevious,
  deleteBackward,
  deleteForward,

  /// Presses a focused button, checkbox or radio; types a space in a field; else scrolls down a page.
  space,
  selectAll,
  undo,
  redo,
  cut,
  copy,
  arrowUp,
  arrowDown,
  arrowLeft,
  arrowRight,
  pageUp,
  pageDown,
  home,
  end,
}

/// The default action of [k] (from [parseKeyPress]).
KeyDefault keyDefaultOf(({String key, String code, int vk, String? text, int modifiers}) k) {
  final shortcut = k.modifiers & (cdpControl | cdpMeta) != 0;
  final shift = k.modifiers & cdpShift != 0;
  if (shortcut) {
    return switch (editingCommandFor(k.code, shift: shift)) {
      'selectAll' => KeyDefault.selectAll,
      'undo' => KeyDefault.undo,
      'redo' => KeyDefault.redo,
      'cut' => KeyDefault.cut,
      'copy' => KeyDefault.copy,
      _ => KeyDefault.none,
    };
  }
  return switch (k.code) {
    'Enter' || 'NumpadEnter' => KeyDefault.enter,
    'Tab' => shift ? KeyDefault.focusPrevious : KeyDefault.focusNext,
    'Backspace' => KeyDefault.deleteBackward,
    'Delete' => KeyDefault.deleteForward,
    'Space' => KeyDefault.space,
    'ArrowUp' => KeyDefault.arrowUp,
    'ArrowDown' => KeyDefault.arrowDown,
    'ArrowLeft' => KeyDefault.arrowLeft,
    'ArrowRight' => KeyDefault.arrowRight,
    'PageUp' => KeyDefault.pageUp,
    'PageDown' => KeyDefault.pageDown,
    'Home' => KeyDefault.home,
    'End' => KeyDefault.end,
    _ when (k.text ?? '').isNotEmpty => KeyDefault.insertText,
    _ => KeyDefault.none,
  };
}

/// Safari's user agent on this Mac, so sign-in pages treat the view as the browser it is (WKWebView's own has no
/// `Version/… Safari/…`, which some sites refuse as an embedded view). [macOSMajor] is the OS's major version.
String safariUserAgent(int macOSMajor) {
  // Safari's major version follows the OS from macOS 26 on; before that it ran three ahead of the OS's.
  final safari = macOSMajor >= 26 ? macOSMajor : macOSMajor + 3;
  return 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) '
      'Version/$safari.0 Safari/605.1.15';
}

/// PNG width and height from its header, or null when [png] isn't one.
({int width, int height})? pngSize(List<int> png) {
  if (png.length < 24 || png[0] != 0x89 || png[1] != 0x50 || png[2] != 0x4E || png[3] != 0x47) return null;
  int be(int at) => (png[at] << 24) | (png[at + 1] << 16) | (png[at + 2] << 8) | png[at + 3];
  return (width: be(16), height: be(20));
}
