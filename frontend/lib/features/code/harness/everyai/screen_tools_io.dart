// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../../../../core/security/official_sites.dart';
import '../../../../core/security/untrusted.dart';
import '../../live/frames.dart';
import '../../live/live_session.dart';
import 'browser_io.dart';
import 'exfil.dart';
import 'tools_io.dart' show ToolOutput, imageDataUrl;
import 'window_ax_io.dart';
import 'window_capture_io.dart';

// The browser and screenshot tools' work, shared by the EveryAI harness's
// own tools and the app's MCP host (outside agents).

/// Runs one browser tool call ([args] as the `browser` spec has them) on [b].
/// Screenshots go under [root]'s `.everyai/scratch/screenshots/`, downloads
/// under its `.everyai/scratch/downloads/`; [fit] cuts
/// a long eval result (text, a name for its spill file).
Future<ToolOutput> runBrowser(
  HeadlessBrowser b,
  Map<String, Object?> args, {
  required String root,
  required bool vision,
  required String Function(String text, String name) fit,
  String Function(String text)? scrub,
}) async {
  final action = args['action'] as String? ?? '';
  String? str(String k) => (args[k] as String?)?.trim().isEmpty ?? true ? null : (args[k] as String).trim();
  double? at(String k) => (args[k] as num?)?.toDouble();
  var shot = args['screenshot'] == true;
  var list = args['snapshot'] == true;
  // Before the browser starts: the folder its downloads go to.
  b.downloadDir = '$root/.everyai/scratch/downloads';
  // Our own line about the site (a bare IP, a shortener, ...), kept outside the page's untrusted block.
  String? note;
  // The user may be driving the shared page (they took control in the Preview): wait for them, up to a limit.
  if (action != 'close' && !await b.control.agentTurn()) {
    return ToolOutput(userDrivingText(b.control.hold), isError: true);
  }
  final gaveBack = b.control.takeGiveBack();
  ViewRect? zoom;
  try {
    // A link, a script or a form may have taken the page to another site since the last action: judge it before
    // acting on it.
    if (action != 'open' && action != 'close' && b.running) {
      final here = await b.evaluate('location.href');
      if (here is String) {
        final now = browserLanded(_judged[b] ?? 'about:blank', here);
        _judged[b] = here;
        if (now.refusal case final refusal?) {
          await b.open('about:blank');
          _judged[b] = 'about:blank';
          return ToolOutput(
            'The page went to another site, so the browser went back to a blank page.\n$refusal',
            isError: true,
          );
        }
        note = now.notice;
      }
    }
    final String did;
    switch (action) {
      case 'open':
        final url = str('url');
        if (url == null) return const ToolOutput('Error: open needs a url.', isError: true);
        // A bare path or localhost:port is what agents often pass.
        final target = url.startsWith('/')
            ? Uri.file(url).toString()
            : RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false).hasMatch(url) && !url.startsWith('localhost:')
            ? url
            : 'http://$url';
        if (_openRefusal(target) case final refusal?) return ToolOutput(refusal, isError: true);
        final before = browserTarget(target);
        if (before.refusal case final refusal?) return ToolOutput(refusal, isError: true);
        final opened = await b.open(target);
        // Chrome follows redirects itself: judge where it landed too.
        final landed = await b.evaluate('location.href');
        final after = landed is String ? browserLanded(target, landed) : _clear;
        _judged[b] = landed is String ? landed : target;
        if (after.refusal case final refusal?) {
          await b.open('about:blank');
          _judged[b] = 'about:blank';
          final where = 'The page redirected to another site, so the browser went back to a blank page.';
          return ToolOutput('$where\n$refusal', isError: true);
        }
        note = [before.notice, after.notice].nonNulls.join('\n');
        did = 'Opened $opened';
        b.control.report(LiveActivity('open', caption: 'Opening $target'));
        // The element list comes with every page opened: refs to click, cheaper than a picture.
        list = true;
      case 'click':
        final sel = str('selector'), ref = str('ref');
        final count = (args['count'] as num?)?.toInt() ?? 1;
        if (ref != null || sel != null) {
          did = await b.click(selector: sel, ref: ref, count: count);
        } else if (at('x') == null || at('y') == null) {
          return const ToolOutput('Error: click needs a ref, a selector, or x and y.', isError: true);
        } else {
          final p = await _point(b, str('frame'), at('x')!, at('y')!);
          if (p.refusal case final why?) return ToolOutput('Error: $why', isError: true);
          did = await b.click(x: p.x, y: p.y, count: count);
          if (p.warning case final w?) note = [?note, w].join('\n');
        }
      case 'type':
        final text = args['text'] as String?;
        if (text == null) return const ToolOutput('Error: type needs text.', isError: true);
        did = await b.type(text, selector: str('selector'), ref: str('ref'), submit: args['submit'] == true);
      case 'snapshot':
        list = true;
        did = 'Element list:';
      case 'zoom':
        final x = at('x'), y = at('y'), w = at('width'), h = at('height');
        if (x == null || y == null || w == null || h == null || w <= 0 || h <= 0) {
          return const ToolOutput('Error: zoom needs x, y, width and height (in the frame\'s pixels).', isError: true);
        }
        final from = await _point(b, str('frame'), x, y), to = await _point(b, str('frame'), x + w, y + h);
        if (from.refusal ?? to.refusal case final why?) return ToolOutput('Error: $why', isError: true);
        zoom = (left: from.x, top: from.y, width: to.x - from.x, height: to.y - from.y);
        shot = true;
        did =
            'Zoomed into (${from.x.round()}, ${from.y.round()}) ${(to.x - from.x).round()}×${(to.y - from.y).round()} '
            'of the page.';
      case 'back' || 'forward' || 'reload':
        await switch (action) {
          'back' => b.back(),
          'forward' => b.forward(),
          _ => b.reload(),
        };
        await Future<void>.delayed(const Duration(milliseconds: 600));
        did = '${action[0].toUpperCase()}${action.substring(1)}: ${await b.describe()}';
      case 'press':
        did = await b.press(str('key') ?? 'Enter');
      case 'scroll':
        did = await b.scroll(at('dy') ?? 600, x: at('x'), y: at('y'));
      case 'wait':
        did = await b.wait(selector: str('selector'), ms: (args['ms'] as num?)?.toInt() ?? 5000);
      case 'eval':
        final script = args['script'] as String?;
        if (script == null || script.trim().isEmpty) {
          return const ToolOutput('Error: eval needs a script.', isError: true);
        }
        final here = await b.evaluate('location.href');
        if (evalRefusal(script, here is String ? here : '') case final why?) return ToolOutput(why, isError: true);
        final value = const JsonEncoder.withIndent('  ').convert(await b.evaluate(script));
        did = 'Result: ${fit(scrub == null ? value : scrub(value), 'browser-eval')}';
      case 'screenshot':
        shot = true;
        did = 'Screenshot of ${await b.describe()}';
      case 'console':
        final old = b.history;
        did = old.isEmpty
            ? 'Console:'
            : 'Console (the last ${old.length} lines, oldest first; new ones below):\n${old.join('\n')}';
      case 'resize':
        did = await b.resize((args['width'] as num?)?.toInt() ?? 1280, (args['height'] as num?)?.toInt() ?? 800);
      case 'close':
        await b.close();
        _judged[b] = null;
        return const ToolOutput('Closed the browser.');
      default:
        return ToolOutput('Error: unknown browser action "$action".', isError: true);
    }
    final listed = list ? '\n${await b.snapshot()}' : '';
    final page = browserResultText(list ? 'snapshot' : action, '$did$listed', b.takeLog());
    final notes = [if (gaveBack) gaveBackText, ?note].where((n) => n.isNotEmpty).join('\n');
    final text = notes.isEmpty ? page : '$notes\n$page';
    if (!shot) return ToolOutput(text);
    final dir = Directory('$root/.everyai/scratch/screenshots')..createSync(recursive: true);
    final path = '${dir.path}/browser-${DateTime.now().millisecondsSinceEpoch}.png';
    final shown = path.startsWith('$root/') ? path.substring(root.length + 1) : path;
    if (args['full_page'] == true && zoom == null) {
      // A whole long page: for reading, not for coordinates.
      final png = await b.screenshot(fullPage: true);
      File(path).writeAsBytesSync(png);
      final url = vision ? await _pngDataUrl(png) : null;
      if (url == null) return ToolOutput('$text\nSaved the screenshot to $path (this model can\'t view images).');
      return ToolOutput(
        '$text\nFull-page screenshot: $path. Its points are not for clicking: take a plain screenshot for that.',
        images: [(label: path, dataUrl: url)],
      );
    }
    b.control.report(const LiveActivity('look', caption: 'Looking'));
    final (png, frame) = await b.frameShot(region: zoom);
    File(path).writeAsBytesSync(png);
    final url = vision ? await _pngDataUrl(png) : null;
    if (url == null) {
      return ToolOutput(
        '$text\nSaved the screenshot to $path (this model can\'t view images: use the element list, snapshot, and '
        'click by ref).',
      );
    }
    final where = frame.zoomed
        ? 'a zoom of part of the page at ${frame.imageWidth}×${frame.imageHeight}'
        : 'the page at ${frame.imageWidth}×${frame.imageHeight}';
    return ToolOutput(
      '$text\nFrame ${frame.id}: $where ($shown). To click something in it, pass frame: "${frame.id}" with x and y '
      'in this picture\'s pixels.',
      images: [(label: path, dataUrl: url)],
    );
  } on BrowserError catch (e) {
    return ToolOutput(browserErrorText(e.fromPage ? action : '', e.message, b.takeLog()), isError: true);
  }
}

/// Where the model's [x],[y] in frame [frame] (null: its latest) lands on [b]'s page. Before any screenshot the
/// point is taken as CSS pixels of the viewport, as the model may know them from the page itself.
Future<FramePoint> _point(HeadlessBrowser b, String? frame, double x, double y) async {
  if (b.frames.latest == null && (frame == null || frame.isEmpty)) return FramePoint(x, y);
  final at = await b.scrollOffset();
  return b.frames.map(frame, x, y, b.geometry, scrollX: at.x, scrollY: at.y);
}

/// Why the agent's eval [script] on the page at [pageUrl] is refused: it reads the shared profile's cookies, storage
/// or saved credentials (the user's sign-ins live there), or sends something to another site. Null when it may run.
/// A tripwire on the script's text, like the field guards.
String? evalRefusal(String script, String pageUrl) {
  const storage =
      r'document\s*\.\s*cookie|cookieStore|localStorage|sessionStorage|indexedDB|caches\s*\.|navigator\s*\.\s*credentials|'
      r'PasswordCredential|FederatedCredential';
  if (RegExp(storage).hasMatch(script)) {
    return 'Refused: the script reads cookies, storage or saved credentials. The Preview browser keeps the user\'s '
        'sign-ins, so eval may not touch them. Check what the page shows instead (snapshot, screenshot), or ask the '
        'user.';
  }
  const network =
      r'\bfetch\s*\(|XMLHttpRequest|sendBeacon|new\s+WebSocket|new\s+EventSource|\.src\s*=|location\s*(\.\s*href\s*)?=|window\s*\.\s*open\s*\(|import\s*\(';
  if (!RegExp(network).hasMatch(script)) return null;
  final here = Uri.tryParse(pageUrl)?.host ?? '';
  for (final m in RegExp(r'''(?:https?:)?//([A-Za-z0-9.-]+)''').allMatches(script)) {
    final host = m.group(1)!.toLowerCase();
    if (host != here.toLowerCase() && !_localHost(host)) {
      return 'Refused: the script sends a request to $host, another site than the page. Open that site with the '
          'browser\'s open action instead.';
    }
  }
  return null;
}

/// Why the browser may not open [target]: a file in one of the user's credential stores (the browser would show
/// it), or a site that takes uploads. Checked here, so the outside leads' host browser has the same guard.
String? _openRefusal(String target) {
  final uri = Uri.tryParse(target);
  if (uri == null) return null;
  if (uri.isScheme('file')) {
    var path = uri.toFilePath();
    try {
      if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
        path = File(path).resolveSymbolicLinksSync();
      }
    } on FileSystemException {
      // Checked as written.
    }
    final what = credentialPath(path, home: Platform.environment['HOME'] ?? '');
    return what == null ? null : guardRefusal('the file holds $what');
  }
  final site = exfilHost(uri.host);
  return site == null ? null : guardRefusal('$site is a site that takes uploads');
}

const _clear = (refusal: null, notice: null);

/// The address each browser's page was last judged at, so a later action notices when it moved.
final _judged = Expando<String>('browser page judged');

/// The user took [b]'s page to [url] themselves (the Preview's address bar): the agent's next action starts from
/// there instead of judging the user's move as a redirect.
void noteUserNavigation(HeadlessBrowser b, String url) => _judged[b] = url;

/// What the browser tool makes of [target] (before opening it, and again where a redirect landed): the refusal
/// for a look-alike of an official site, a one-line note for a host with a reason for doubt (a bare IP address, a
/// link shortener, `github.co`), or neither. The agent's own apps are never judged: files, localhost, private
/// addresses and `.local` names. Checked here, so the outside leads' host browser has the same guard.
({String? refusal, String? notice}) browserTarget(String target) {
  final uri = Uri.tryParse(_unwrapped(target));
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || _localHost(uri.host)) return _clear;
  final v = judgeHost(uri.host);
  final shown = _shownHost(uri.host);
  return switch (v.verdict) {
    SiteVerdict.ok => _clear,
    SiteVerdict.warn => (refusal: null, notice: siteNotice(shown, v)),
    SiteVerdict.refuse => (refusal: guardRefusal(siteRefusal(shown, v)), notice: null),
  };
}

/// [browserTarget] for the page Chrome [landed] on after opening [target] (or after an earlier action at [target]),
/// when it is now on another host. Hosts are compared as a person reads them, so a site gets no second note for
/// being written another way (Chrome writes `xn--` where Dart's Uri percent-encodes; `www.` is dropped).
({String? refusal, String? notice}) browserLanded(String target, String landed) =>
    readableHost(_hostOf(target)) == readableHost(_hostOf(landed)) ? _clear : browserTarget(landed);

/// What `view-source:` shows is the page under it.
String _unwrapped(String url) =>
    url.toLowerCase().startsWith('view-source:') ? _unwrapped(url.substring('view-source:'.length)) : url;

String _hostOf(String url) => Uri.tryParse(_unwrapped(url))?.host ?? '';

/// [host] as a person reads it (Dart's Uri percent-encodes non-ASCII hosts).
String _shownHost(String host) {
  try {
    return Uri.decodeComponent(host);
  } on Object {
    return host;
  }
}

/// The agent's own machine or network: localhost, loopback, private and link-local addresses, `.local` names.
bool _localHost(String host) {
  final h = host.toLowerCase();
  if (h.isEmpty || h == 'localhost' || h.endsWith('.localhost') || h.endsWith('.local')) return true;
  final ip = InternetAddress.tryParse(h);
  if (ip == null) return false;
  if (ip.isLoopback || ip.isLinkLocal) return true;
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return b[0] == 0 || b[0] == 10 || (b[0] == 172 && b[1] & 0xf0 == 16) || (b[0] == 192 && b[1] == 168);
  }
  return b[0] & 0xfe == 0xfc; // fc00::/7 unique local
}

/// Actions whose result carries text the page controls (its title, an eval result, the console, a hit's class names).
const _pageTextActions = {'open', 'eval', 'screenshot', 'console', 'click', 'snapshot', 'back', 'forward', 'reload'};

const _page = 'browser page';

/// A browser action's result text: what was done ([did]) and the page's log
/// since the last call, in an untrusted block when any of it comes from the
/// page.
String browserResultText(String action, String did, List<String> log) {
  final text = [
    did,
    if (log.isNotEmpty) 'Page log:\n${log.join('\n')}' else if (action == 'console') '(nothing new)',
  ].join('\n');
  return log.isEmpty && !_pageTextActions.contains(action) ? text : untrusted(text, source: _page);
}

/// A failed browser action's text. The message of a page-text action (an
/// eval that threw, a click hit) can quote the page, so it goes in the block
/// with the page log; otherwise only the log does.
String browserErrorText(String action, String message, List<String> log) {
  final logText = log.isEmpty ? '' : 'Page log:\n${log.join('\n')}';
  if (_pageTextActions.contains(action)) {
    return 'Error: the browser action failed.\n${untrusted([message, if (logText.isNotEmpty) logText].join('\n'), source: _page)}';
  }
  return 'Error: ${stripHidden(message)}${logText.isEmpty ? '' : '\n${untrusted(logText, source: _page)}'}';
}

/// [text] with the window's accessibility tree [ax] after it, in an untrusted block (labels are the app's text).
/// A note instead of a tree (permission off) is our own line and stays outside the block.
String withAx(String text, String ax) {
  final isNote = axNotes.contains(ax);
  return '$text\n\nWindow accessibility tree:\n${isNote ? ax : untrusted(ax, source: 'window accessibility')}';
}

/// Captures window [w] to `.everyai/scratch/screenshots/` under [root] and
/// returns its picture; [others] more windows matched, which the text
/// mentions. On macOS the window's accessibility tree ([ax]) follows the text.
Future<ToolOutput> captureFor(
  ScreenWindow w, {
  required String root,
  required bool vision,
  int others = 0,
  Future<String> Function(ScreenWindow w) ax = windowAxTree,
}) async {
  final dir = Directory('$root/.everyai/scratch/screenshots')..createSync(recursive: true);
  final path = '${dir.path}/window-${DateTime.now().millisecondsSinceEpoch}.png';
  if (await captureWindow(w.id, path) case final problem?) return ToolOutput('Error: $problem', isError: true);
  final label = windowLabel(w);
  final more = others > 0 ? ' $others other window(s) of this session\'s apps; pick with app.' : '';
  final (url, tree) = await (
    _pngDataUrl(File(path).readAsBytesSync()),
    Platform.isMacOS ? ax(w) : Future<String?>.value(),
  ).wait;
  String text(String t) => tree == null ? t : withAx(t, tree);
  if (!vision || url == null) {
    return ToolOutput(text('Saved a screenshot of $label to $path (this model can\'t view images).$more'));
  }
  return ToolOutput(text('Screenshot of $label: $path.$more'), images: [(label: path, dataUrl: url)]);
}

/// [imageDataUrl] for a PNG, off the calling isolate: shrinking a Retina
/// window's picture takes long enough to freeze the app's UI.
Future<String?> _pngDataUrl(List<int> png) => Isolate.run(() => imageDataUrl(png, 'png'));
