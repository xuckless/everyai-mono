// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart' show TargetPlatform, ValueNotifier;

import 'browser_jar.dart' show JarData, JarHome;
import 'frames.dart';
import 'live_session.dart';
import 'login_wall.dart';
import 'page_snapshot.dart';

/// A Code session's browser page, whatever runs it: what the agent's browser tool, the host's browser tool, the
/// login wall and the Preview use. Two kinds:
///
/// - [StreamedPage]: a page drawn as a picture stream the Preview paints and forwards input to (headless Chrome over
///   the DevTools protocol, and Electron apps attached the same way).
/// - a page in a native view the Preview embeds (the OS webview), with no picture stream.
///
/// The Preview tells them apart with `page is StreamedPage`.
abstract interface class BrowserPage {
  // ----------------------------------------------------------- driving and frames

  /// Who drives the page (agent or user), and the agent's actions for the Preview's ghost cursor.
  LiveControl get control;

  /// The pictures of the page the model has seen, for checking and mapping its coordinates.
  FrameBook get frames;

  /// The page's size now, in CSS pixels.
  ViewGeometry get geometry;

  /// Width and height of the viewport, in CSS pixels.
  int get width;
  int get height;

  // ----------------------------------------------------------- state

  /// The page's address, title and history, for the Preview's bar.
  ValueNotifier<PageState> get page;

  /// The session's tabs, in the order they opened; the active one is [activeTab].
  ValueNotifier<List<BrowserTab>> get tabs;

  /// The tab the agent and the Preview act on.
  String? get activeTab;

  /// The dialog the active page waits on, or null.
  ValueNotifier<PageDialog?> get dialog;

  /// The file picker the active page opened, or null.
  ValueNotifier<FileChooser?> get fileChooser;

  /// This session's downloads (the last 20).
  ValueNotifier<List<BrowserDownload>> get downloads;

  /// The login wall: the agent's call waits on a sign-in page until the user signs in or skips.
  LoginWall get loginWall;

  /// Saved logins this session started from, by site: their refreshed sign-ins are written back.
  Map<String, String> get usedLogins;

  /// Where the session's own cookie jar is kept, or null (the profile's shared cookies).
  JarHome? get jarHome;

  bool get running;

  /// Where downloads go, set before the browser starts (the session's scratch folder); null refuses downloads.
  String? get downloadDir;
  set downloadDir(String? dir);

  /// The dialog another tab waits on that holds up the active one too, with that tab's number (from 1), or null.
  ({int tab, PageDialog dialog})? get dialogHoldingThis;

  /// The dialog another tab of the session waits on, with its tab's number (from 1), or null.
  ({int tab, PageDialog dialog})? get dialogElsewhere;

  // ----------------------------------------------------------- the agent's actions

  Future<String> open(String url);

  /// The page's address and title. [bare]: the address without its query and fragment.
  Future<String> describe({bool bare = false});

  Future<Object?> evaluate(String script);

  /// PNG bytes of the viewport, or of the whole page with [fullPage].
  Future<List<int>> screenshot({bool fullPage = false});

  /// A picture of [region] of the viewport (null: all of it) for the model, and the frame it is recorded as.
  Future<(List<int>, AgentFrame)> frameShot({ViewRect? region});

  /// The page's scroll offset now.
  Future<({double x, double y})> scrollOffset();

  /// The page's elements now, for what an action changed; empty when the page gives none.
  Future<List<PageElement>> elements();

  /// The page's element list: what the model clicks by ref.
  Future<String> snapshot();

  /// The centre of element [ref] of the last element list, scrolled into view.
  Future<({double x, double y})> refCentre(String ref);

  /// [guarded] false lifts the password, one-time code and payment field refusals (the user's switch).
  Future<String> click({String? selector, String? ref, double? x, double? y, int count = 1, bool guarded = true});
  Future<String> type(String text, {String? selector, String? ref, bool submit = false, bool guarded = true});

  /// Types a saved login's [value] with no field guard; the value reaches no log, caption or error text.
  /// [lastCheck] runs after the field was clicked and selected, right before the value goes to the page: a text
  /// from it refuses ([FillRefused]) and nothing is typed.
  Future<String> typeSecret(
    String value, {
    String? selector,
    String? ref,
    bool submit = false,
    Future<String?> Function()? lastCheck,
  });

  /// What the focused field is: "a password field", "a one-time code field", null for an ordinary one, '' when
  /// nothing that takes text has the focus.
  Future<String?> focusedFieldKind();
  Future<String> press(String key, {bool guarded = true});
  Future<String> scroll(double dy, {double? x, double? y});
  Future<String> wait({String? selector, int ms = 5000});
  Future<String> resize(int w, int h);

  /// The page's address and whether it shows a password field (for the login wall); null when it can't tell.
  Future<LoginProbe?> loginProbe();

  /// Closes the page. [captured]: the caller read the jar just now (at quit).
  Future<void> close({bool captured = false});

  Future<void> switchTab(String id);
  Future<void> openTab(String url);
  Future<void> closeTab(String id);
  Future<void> answerDialog({required bool accept, String? text});
  Future<void> setFiles(List<String> paths, {String? selector, String? ref});

  /// Leaves the page's file picker without files.
  void cancelFileChooser();

  /// What the page logged since the last call; cleared on read (the last 50 lines stay in [history]).
  List<String> takeLog();

  /// The last 50 lines the page logged, read or not.
  List<String> get history;

  Future<void> back();
  Future<void> forward();
  Future<void> reload();

  // ----------------------------------------------------------- the user's own (the Preview)

  /// Goes to [url] for the user (the address bar).
  Future<void> userOpen(String url);

  /// Sets the page's size (the Preview's size menu): frames taken before no longer map.
  Future<void> setSize(int w, int h);

  /// What is at [x],[y] (CSS pixels), for the Preview's right-click menu; null when it can't be read.
  Future<PageContext?> contextAt(double x, double y);

  /// Finds [text] in the page from the selection on (wrapping); how many times the page's text has it.
  Future<int> findText(String text, {bool backwards = false});

  /// The page's selected text (the user's copy).
  Future<String> selectedText();

  /// Runs the browser's editing [command] (`selectAll`, `cut`, `undo`…) in the focused field.
  Future<void> userCommand(String command);

  /// Text the user pasted or composed, inserted at the caret.
  Future<void> userText(String text);

  // ----------------------------------------------------------- the session's cookie jar and sign-ins

  /// The jar as it is now: the context's cookies and the storage read from its pages.
  Future<JarData> captureJar();

  /// Saves the jar now (captured first while running, unless [captured]: the caller just did).
  Future<void> saveJar({bool captured = false});

  /// The session was removed: its jar is deleted, and nothing is saved when the browser closes.
  Future<void> forgetJar();

  /// Adds [data] (a saved login, or a sign-in made in a real window) to the session.
  Future<void> applyJar(JarData data, {String? site, String? loginId});

  /// Signs the session out of [site], or of everything.
  Future<void> clearJar({String? site});

  /// The sites this session is signed in to (it has cookies for), from the last reading.
  List<String> get signedInSites;

  /// The sign-ins in the project's shared profile: its cookies for [site], or for every site.
  Future<JarData> profileSignIns({String? site});
}

/// A [BrowserPage] drawn as a picture stream: the Preview paints its frames and forwards the user's mouse and keys.
abstract interface class StreamedPage implements BrowserPage {
  /// The page's screencast while [startScreencast] runs.
  Stream<ScreencastFrame> get screencast;

  /// Starts painting frames into [screencast] (the Preview is showing).
  Future<void> startScreencast();

  /// Starts the screencast again with a fresh picture (the Preview saw the page change and no frame came).
  Future<void> refreshScreencast();

  Future<void> stopScreencast();

  /// Tells the page frame [session] was painted, so it sends the next.
  void ackFrame(int session);

  /// A mouse event from the user's view, in CSS pixels: `mouseMoved`, `mousePressed`, `mouseReleased`,
  /// `mouseWheel`.
  Future<void> userMouse(
    String type,
    double x,
    double y, {
    String button = 'none',
    int buttons = 0,
    int clickCount = 0,
    int modifiers = 0,
    double deltaX = 0,
    double deltaY = 0,
  });

  /// A key event from the user's view (`keyDown` with [text] for printable keys, `rawKeyDown`, `keyUp`).
  Future<void> userKey(
    String type, {
    required String key,
    required String code,
    int keyCode = 0,
    String? text,
    int modifiers = 0,
    List<String> commands = const [],
  });
}

/// Which kind of page a session's browser is made as (see [backendFor]).
enum BrowserBackend {
  /// Headless Chrome over the DevTools protocol, painted as a screencast ([StreamedPage]).
  chromeStream,

  /// The OS webview (WKWebView, WebView2) embedded in the Preview.
  osWebview,
}

/// The backend a session's browser uses on [platform]: the OS webview where the webview plugin has one (macOS's
/// WKWebView, Windows' WebView2), Chrome's stream elsewhere (Linux). [choice] is `EVERYAI_BROWSER` (`chrome` or
/// `webview`; anything else is ignored); without [platformViews] (`flutter test`, which has none) it is Chrome, as the
/// webview can't run there.
BrowserBackend backendFor(TargetPlatform platform, {String? choice, bool platformViews = true}) {
  final webviewHere = switch (platform) {
    TargetPlatform.macOS || TargetPlatform.windows => true,
    TargetPlatform.linux || TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => false,
  };
  return switch ((choice?.trim().toLowerCase(), webviewHere && platformViews)) {
    ('chrome', _) => BrowserBackend.chromeStream,
    (_, false) => BrowserBackend.chromeStream,
    (_, true) => BrowserBackend.osWebview,
  };
}

/// A frame of a page's screencast: JPEG bytes, its size, and what to ack.
typedef ScreencastFrame = ({List<int> jpeg, int width, int height, double scrollY, int session});

/// What the Preview shows about the page: its address and title, and whether it can go back or forward.
typedef PageState = ({String url, String title, bool canBack, bool canForward, bool loading});

/// A tab of a session's browser: the session's own page, or one a page of it opened (a pop-up, a link to a new tab).
typedef BrowserTab = ({String id, String url, String title});

/// A dialog the page opened and waits on (`alert`, `confirm`, `prompt`, `beforeunload`).
typedef PageDialog = ({String type, String message, String defaultPrompt});

/// A file picker the page opened (a click on a file input): what to set the files on.
typedef FileChooser = ({int backendNodeId, bool multiple});

/// A download of the session's browser, newest last.
typedef BrowserDownload = ({String guid, String name, String? path, String state, double progress});

/// What is under the pointer for the Preview's right-click menu.
typedef PageContext = ({
  bool prevented,
  String? link,
  String? image,
  bool editable,
  String selection,
  String description,
});

class BrowserError implements Exception {
  const BrowserError(this.message, {this.fromPage = false});
  final String message;

  /// The message quotes the page (a script's exception), so it goes in the page's untrusted block.
  final bool fromPage;
  @override
  String toString() => message;
}

/// A saved login's fill was stopped by its last check ([BrowserPage.typeSecret]'s `lastCheck`): nothing was typed.
final class FillRefused extends BrowserError {
  const FillRefused(super.message);
}

/// The tab a call went to closed before it answered (a pop-up that closed itself on the click).
final class TabClosedError extends BrowserError {
  const TabClosedError() : super('The tab closed before it answered.');
}

/// What the agent is told while the page waits on [d].
String dialogWaitingText(PageDialog d) {
  final what = switch (d.type) {
    'beforeunload' => 'asks whether to leave the page',
    'confirm' => 'asks to confirm',
    'prompt' => 'asks for text',
    _ => 'shows an alert',
  };
  return 'The page $what: "${d.message}". It waits until the dialog is answered: browser {action: "dialog", '
      'accept: true or false${d.type == 'prompt' ? ', text' : ''}}, or the user answers it in the Preview.';
}

/// [url]'s origin when it is a web page (http or https), else null (file:, about:, data:).
String? webOrigin(String url) {
  final u = Uri.tryParse(url);
  return u != null && (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty ? u.origin : null;
}

/// Page helpers for the field guards: `sensitive(el)` says what a password, one-time
/// code or payment field is ("a password field") or null; `sensitiveForm(f)`
/// the same for a form holding one; `focused()` is the focused element,
/// through shadow roots and same-origin frames (other frames: the backend looks
/// inside them itself); `submits(el)` is what makes the form a submit control
/// [el] sends sensitive, or null; `deep(x, y)` is the element at a point, through
/// shadow roots. A frame also counts by its name (Stripe and the like put card
/// fields in their own frame). Names in other languages, canvas fields, div
/// "buttons" and clicks inside another origin's frame are missed: a tripwire,
/// not a sandbox. Every backend runs its checks after this text.
const pageFieldGuardJs = r'''
const cardName = /card.?(number|num)|cardno|card.?no(?![a-z])|ccnum|security.?code|sort.?code|routing.?number|account.?number|(?<![a-z])(cvv|cvc|csc|iban)(?![a-z])/i;
const payFrame = /stripe|braintree|adyen|paypal|checkout|card|payment/i;
const sensitive = (el) => {
  if (!el || !el.tagName) return null;
  const tag = el.tagName.toLowerCase();
  if (tag === 'iframe') {
    return payFrame.test([el.src, el.name, el.title].join(' ')) ? 'in a payment frame' : null;
  }
  if (tag === 'input' && (el.type || '').toLowerCase() === 'password') return 'a password field';
  const ac = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
  if (ac.includes('current-password') || ac.includes('new-password')) return 'a password field';
  if (ac.includes('one-time-code')) return 'a one-time code field';
  if (ac.some((t) => t.startsWith('cc-'))) return 'a payment card field';
  const names = [el.getAttribute('name'), el.id, el.getAttribute('aria-label')].filter(Boolean).join(' ');
  return cardName.test(names) ? 'a payment field' : null;
};
const sensitiveForm = (f) => {
  for (const el of [...(f.elements || []), ...f.querySelectorAll('iframe')]) {
    const why = sensitive(el);
    if (why) return why === 'in a payment frame' ? 'a payment frame' : why;
  }
  return null;
};
const submits = (el) => {
  const c = el && el.closest && el.closest('button, input[type=submit i], input[type=image i]');
  const f = c && c.type !== 'button' && c.type !== 'reset' ? c.form : null;
  return f ? sensitiveForm(f) : null;
};
const inside = (el) => {
  try { return el.contentDocument && el.contentDocument.activeElement; } catch (e) { return null; }
};
const focused = () => {
  let el = document.activeElement;
  for (;;) {
    const next = (el && el.shadowRoot && el.shadowRoot.activeElement) || (el && el.tagName === 'IFRAME' && inside(el));
    if (!next || next === el || next.tagName === 'BODY') return el;
    el = next;
  }
};
const deep = (x, y) => {
  let el = document.elementFromPoint(x, y);
  while (el && el.shadowRoot) {
    const under = el.shadowRoot.elementFromPoint(x, y);
    if (!under || under === el) break;
    el = under;
  }
  return el;
};''';

/// An expression for where the page's focus is: `{url}` (the top page's address, or the origin of the same-origin
/// frame holding the focus) or `{foreign: true}` (focus inside a frame whose document the page can't read: another
/// origin, or a sandboxed one). Over [pageFieldGuardJs]'s `focused()`. Page script could lie to it: a tripwire, like
/// the field guards.
const focusDocumentJs =
    '(() => { $pageFieldGuardJs\n'
    'const el = focused();\n'
    'if (el && (el.tagName === "IFRAME" || el.tagName === "FRAME")) return {foreign: true};\n'
    'const doc = (el && el.ownerDocument) || document;\n'
    'if (doc === document) return {url: location.href};\n'
    'const o = doc.defaultView && doc.defaultView.location.origin;\n'
    'return !o || o === "null" ? {foreign: true} : {url: o}; })()';
