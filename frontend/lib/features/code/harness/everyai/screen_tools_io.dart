// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../../../../core/security/official_sites.dart';
import '../../../../core/security/untrusted.dart';
import '../../live/agent_logins.dart';
import '../../live/app_view.dart';
import '../../live/frames.dart';
import '../../live/live_session.dart';
import '../../live/login_wall.dart';
import 'browser_io.dart';
import 'exfil.dart';
import 'research_sites.dart' show secretPath;
import 'tools_io.dart' show ToolOutput, imageDataUrl;
import 'window_ax_io.dart';
import 'window_capture_io.dart';

// The browser and screenshot tools' work, shared by the EveryAI harness's
// own tools and the app's MCP host (outside agents).

/// Runs one browser tool call ([args] as the `browser` spec has them) on [b].
/// Screenshots go under [root]'s `.everyai/scratch/screenshots/`, downloads
/// under its `.everyai/scratch/downloads/`; [fit] cuts
/// a long eval result (text, a name for its spill file). [logins]: the saved logins the agent may fill and the
/// user's switches for them (null: none to fill, and the switches as they are by default).
Future<ToolOutput> runBrowser(
  BrowserPage b,
  Map<String, Object?> args, {
  required String root,
  required bool vision,
  required String Function(String text, String name) fit,
  String Function(String text)? scrub,
  Duration loginHold = const Duration(minutes: 10),
  LoginAccess? logins,
}) async {
  final out = await _runBrowser(b, args, root, vision, fit, scrub, loginHold, logins);
  // Values filled this session never come back, whatever the page did with them.
  if (logins == null) return out;
  final text = logins.redact(out.text);
  return identical(text, out.text) || text == out.text
      ? out
      : ToolOutput(text, isError: out.isError, observation: out.observation, images: out.images);
}

Future<ToolOutput> _runBrowser(
  BrowserPage b,
  Map<String, Object?> args,
  String root,
  bool vision,
  String Function(String text, String name) fit,
  String Function(String text)? scrub,
  Duration loginHold,
  LoginAccess? logins,
) async {
  // The user's switches: with "type into password fields" on, the field guards are off for type, press and click.
  final guarded = !(logins?.policy ?? LoginPolicy.open).secretFields;
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
  // The page waits on a dialog: only answering it (or the tabs, or closing) gets anywhere.
  if (b.dialog.value case final d? when !const {'dialog', 'tabs', 'tab', 'close'}.contains(action)) {
    return ToolOutput(browserErrorText('', dialogWaitingText(d), b.takeLog()), isError: true);
  }
  // A dialog in a tab this one shares a renderer with (one opened the other) holds this page too: say so now rather
  // than after a 30 s wait.
  if (b.dialogHoldingThis case final other? when !const {'dialog', 'tabs', 'tab', 'close'}.contains(action)) {
    return ToolOutput(
      browserErrorText(
        '',
        'Tab ${other.tab} waits on a dialog, and this tab waits with it (pages opened from one another share one '
            'renderer): switch to tab ${other.tab} and answer it first. ${tabsText(b.tabs.value, b.activeTab)}',
        b.takeLog(),
      ),
      isError: true,
    );
  }
  try {
    // A link, a script or a form may have taken the page to another site since the last action: judge it before
    // acting on it.
    if (!const {'open', 'close', 'dialog', 'tabs', 'tab'}.contains(action) && b.running) {
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
    // Acting on the page: compare its elements before and after, so the result says what the action did.
    final before =
        const {'click', 'type', 'press', 'back', 'forward', 'scroll', 'fill_login'}.contains(action) && b.running
        ? await b.elements()
        : null;
    String did;
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
          did = await b.click(selector: sel, ref: ref, count: count, guarded: guarded);
        } else if (at('x') == null || at('y') == null) {
          return const ToolOutput('Error: click needs a ref, a selector, or x and y.', isError: true);
        } else {
          final p = await _point(b, str('frame'), at('x')!, at('y')!);
          if (p.refusal case final why?) return ToolOutput('Error: $why', isError: true);
          did = await b.click(x: p.x, y: p.y, count: count, guarded: guarded);
          if (p.warning case final w?) note = [?note, w].join('\n');
        }
      case 'type':
        final text = args['text'] as String?;
        if (text == null) return const ToolOutput('Error: type needs text.', isError: true);
        did = await b.type(
          text,
          selector: str('selector'),
          ref: str('ref'),
          submit: args['submit'] == true,
          guarded: guarded,
        );
      case 'logins':
        final here = b.running ? await b.evaluate('location.href') : null;
        did = loginsListText(
          await logins?.usable() ?? const [],
          pageHost: here is String ? Uri.tryParse(here)?.host : null,
          policy: logins?.policy ?? LoginPolicy.open,
        );
      case 'fill_login':
        final filled = await _fillLogin(b, args, logins, str('selector'), str('ref'));
        if (filled.error case final why?) return ToolOutput('Error: $why', isError: true);
        did = filled.did!;
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
        did = await b.press(str('key') ?? 'Enter', guarded: guarded);
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
      case 'tabs':
        did = tabsText(b.tabs.value, b.activeTab);
      case 'tab':
        final i = (args['index'] as num?)?.toInt();
        final all = b.tabs.value;
        if (i == null || i < 1 || i > all.length) {
          return ToolOutput(
            'Error: tab needs an index from 1 to ${all.length}. ${tabsText(all, b.activeTab)}',
            isError: true,
          );
        }
        await b.switchTab(all[i - 1].id);
        // That tab waits on a dialog: it runs no script until it is answered.
        if (b.dialog.value case final d?) {
          return ToolOutput(
            browserErrorText('', 'Switched to tab $i. ${dialogWaitingText(d)}', b.takeLog()),
            isError: true,
          );
        }
        // Another tab's dialog holds up the pages opened from it (they share a renderer): this one may not answer.
        if (b.dialogElsewhere case final other?) {
          return ToolOutput(
            browserErrorText(
              '',
              'Switched to tab $i. Tab ${other.tab} waits on a dialog, and pages opened from one another wait with '
                  'it: switch to tab ${other.tab} and answer it first. ${tabsText(b.tabs.value, b.activeTab)}',
              b.takeLog(),
            ),
            isError: true,
          );
        }
        // A pop-up may be on any site: judge it before the model reads it.
        final here = await b.evaluate('location.href');
        if (here is String) {
          final now = browserLanded(_judged[b] ?? 'about:blank', here);
          if (now.refusal case final refusal?) {
            await b.closeTab(all[i - 1].id);
            return ToolOutput('Closed that tab instead of reading it.\n$refusal', isError: true);
          }
          _judged[b] = here;
          note = now.notice;
        }
        did = 'Switched to tab $i: ${await b.describe()}';
        list = true;
      case 'dialog':
        final d = b.dialog.value;
        if (d == null) return const ToolOutput('Error: the page shows no dialog.', isError: true);
        final accept = args['accept'] != false;
        // The text of a prompt goes to the page: judge its site (from the tab's address; the page runs no script
        // while the dialog is up).
        if (d.type == 'prompt' && accept && (args['text'] as String?)?.isNotEmpty == true) {
          final now = browserLanded(_judged[b] ?? 'about:blank', b.page.value.url);
          if (now.refusal case final refusal?) return ToolOutput(refusal, isError: true);
        }
        await b.answerDialog(accept: accept, text: d.type == 'prompt' && accept ? args['text'] as String? : null);
        did = '${accept ? 'Accepted' : 'Dismissed'} the ${d.type} "${d.message}".';
      case 'upload':
        final files = [
          for (final f in (args['files'] as List<Object?>? ?? const []))
            if (f is String) f,
        ];
        if (files.isEmpty) return const ToolOutput('Error: upload needs files (paths).', isError: true);
        final here = await b.evaluate('location.href');
        if (uploadRefusal(here is String ? here : '', files, root: root) case final why?) {
          return ToolOutput(why, isError: true);
        }
        final paths = [for (final f in files) f.startsWith('/') ? f : '$root/$f'];
        await b.setFiles(paths, selector: str('selector'), ref: str('ref'));
        did = 'Gave the page ${paths.length} file${paths.length == 1 ? '' : 's'}: ${files.join(', ')}.';
      default:
        return ToolOutput('Error: unknown browser action "$action".', isError: true);
    }
    if (before != null && before.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      var change = pageElementsChange(before, await b.elements());
      if (change == null) {
        // Some pages answer after a frame or a fetch.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        change = pageElementsChange(before, await b.elements());
      }
      did = '$did\n${change ?? 'Nothing visible changed on the page.'}';
    }
    // A sign-in page: signing in is the user's. The call waits while a card asks them, then goes on.
    if (b.jarHome != null &&
        b.running &&
        b.dialog.value == null &&
        !const {'tabs', 'dialog', 'console', 'logins'}.contains(action)) {
      final probe = await b.loginProbe();
      final site = probe == null ? null : loginWallSite(probe.url, password: probe.password);
      // A saved login the agent may fill here: no wait, the agent signs in itself.
      final fits = site == null || logins == null || b.loginWall.skipped(site)
          ? const <LoginEntry>[]
          : wallLogins(await logins.usable(), Uri.tryParse(probe!.url)?.host ?? '', policy: logins.policy);
      if (site != null && fits.isNotEmpty) {
        did = '$did\n${wallLoginsText(site, fits)}';
        list = true;
      } else if (site != null && !b.loginWall.skipped(site)) {
        b.control.report(LiveActivity('look', caption: 'Waiting for you to sign in to $site'));
        final outcome = await b.loginWall.hold(site, probe!.url, probe: b.loginProbe, timeout: loginHold);
        did = '$did\n${wallOutcomeText(site, outcome)}';
        if (outcome == WallOutcome.passed && b.running) {
          // The address without its query and fragment: an OAuth callback can carry tokens there.
          did = '$did Now on ${await b.describe(bare: true)}.';
          list = true;
        }
      }
    }
    if (b.fileChooser.value != null && action != 'upload') {
      did = '$did\nA file picker opened: give it files with browser {action: "upload", files: [paths]}.';
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
  } on TabClosedError {
    // A pop-up that closed itself on the click (an OAuth window done), or a tab the user closed meanwhile.
    final now = b.running ? await b.describe().then((d) => d, onError: (Object _) => 'nothing') : 'nothing';
    return ToolOutput(
      browserResultText(
        action,
        'The tab closed during the action (it closed itself, or the user closed it); nothing more was sent to it. '
        'The browser is now on $now.',
        b.takeLog(),
      ),
    );
  } on BrowserError catch (e) {
    return ToolOutput(browserErrorText(e.fromPage ? action : '', e.message, b.takeLog()), isError: true);
  }
}

/// fill_login on [b]'s page: the login named in [args] typed into [selector], [ref] or the focused field. What the
/// result says ([did]) or why it couldn't ([error]); never the value.
Future<({String? did, String? error})> _fillLogin(
  BrowserPage b,
  Map<String, Object?> args,
  LoginAccess? logins,
  String? selector,
  String? ref,
) async {
  final name = (args['login'] as String?)?.trim() ?? '';
  final field = LoginField.parse(args['field'] ?? 'password');
  if (field == null) return (did: null, error: 'fill_login field is "username", "password" or "code".');
  final all = await logins?.usable() ?? const <LoginEntry>[];
  if (logins == null || all.isEmpty) {
    return (
      did: null,
      error: 'there are no saved logins for this project. The user adds them in Settings > Code > Logins; ask them.',
    );
  }
  final e = all.where((l) => l.name == name.toLowerCase()).firstOrNull;
  if (e == null) {
    return (
      did: null,
      error:
          '${name.isEmpty ? 'fill_login needs login' : 'no saved login is called "$name"'}. Saved logins: '
          '${all.map((l) => '${l.name} (${l.site})').join(', ')}.',
    );
  }
  final here = await b.evaluate('location.href');
  if (fillRefusal(e, field, policy: logins.policy, pageUrl: here is String ? here : '') case final why?) {
    return (did: null, error: why);
  }
  if (selector == null && ref == null && await b.focusedFieldKind() == '') {
    return (did: null, error: 'no field has the focus: pass the ref (or selector) of the field to fill.');
  }
  if (await logins.consent(e) case final why?) return (did: null, error: why);
  // The wait for Allow may have lasted minutes: the user may have taken the view, or the page gone elsewhere.
  if (await fillTurnRefusal(b.control) case final why?) return (did: null, error: why);
  final String value;
  try {
    value = await logins.valueOf(e, field);
  } on StateError catch (err) {
    return (did: null, error: err.message);
  }
  final submit = args['submit'] == true;
  try {
    await b.typeSecret(
      value,
      selector: selector,
      ref: ref,
      submit: submit,
      // After the click, right before the value goes: who drives, and where the page and its focus are now.
      lastCheck: () async {
        if (await fillTurnRefusal(b.control) case final why?) return why;
        if (logins.policy.anySite) return null;
        final top = await b.evaluate('location.href');
        return fillSiteRefusal(
          e,
          policy: logins.policy,
          pageUrl: top is String ? top : '',
          focus: focusDocumentOf(await b.evaluate(focusDocumentJs)),
        );
      },
    );
  } on FillRefused catch (r) {
    return (did: null, error: '${r.message} Nothing was typed.');
  }
  return (did: filledText(e, field, into: ref ?? selector, submitted: submit), error: null);
}

/// [v] (the value of [focusDocumentJs]) as a [FocusDocument]; a value that isn't one counts as a foreign frame.
FocusDocument focusDocumentOf(Object? v) => switch (v) {
  {'url': final String url} => FocusIn(url),
  _ => const FocusInForeignFrame(),
};

/// Why a fill can't type now on a view with [control]: the user took it (and didn't give it back within its hold),
/// or took and gave it back since the fill was asked for (the page may have changed under the agent). Null when the
/// agent drives and did all along.
Future<String?> fillTurnRefusal(LiveControl control) async {
  if (!control.userDriving) return null;
  if (!await control.agentTurn()) return userDrivingText(control.hold);
  return 'The user took control of the view while the fill waited and has given it back: look again (snapshot) '
      'before filling, the page may have changed.';
}

/// The logins that fit a sign-in page on [pageHost]: those for its site, or, when the user lets logins fill
/// anywhere and none is for it, all of them.
List<LoginEntry> wallLogins(List<LoginEntry> usable, String pageHost, {required LoginPolicy policy}) {
  final own = [
    for (final l in usable)
      if (loginFitsHost(l.site, pageHost)) l,
  ];
  return own.isNotEmpty || !policy.anySite ? own : usable;
}

/// What the agent reads on a sign-in page to [site] it can fill itself.
String wallLoginsText(String site, List<LoginEntry> fits) =>
    'This page asks to sign in to $site. Saved logins you may fill: '
    '${fits.map((l) => "'${l.name}' (${l.site}${l.username.isEmpty ? '' : ', ${l.username}'})").join(', ')}. '
    'Sign in with fill_login (username, then password, submit: true). If the site then asks for a code sent by text '
    'message or email, ask the user for it.';

/// The session's tabs as the agent sees them, the active one marked.
String tabsText(List<BrowserTab> tabs, String? active) => [
  'Tabs (switch with tab {index}):',
  for (final (i, t) in tabs.indexed)
    '${i + 1}. ${t.title.isEmpty ? '(no title)' : t.title} — ${t.url}${t.id == active ? '  [active]' : ''}',
].join('\n');

/// Why the agent may not give the page at [pageUrl] the files [files]: only the app the session builds (a local
/// page) takes uploads from the agent, and only files of the project ([root]); other sites are the user's to send
/// files to. Null when it may.
String? uploadRefusal(String pageUrl, List<String> files, {required String root}) {
  final uri = Uri.tryParse(pageUrl);
  final host = uri?.host ?? '';
  // A loopback address itself, not a name that starts like one (127.example.com).
  final local =
      uri?.scheme == 'file' ||
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      (InternetAddress.tryParse(host.replaceAll(RegExp(r'^\[|\]$'), ''))?.isLoopback ?? false);
  if (!local) {
    return 'Refused: the agent uploads files only to the app it is building (a local page). Sending files to '
        '${host.isEmpty ? 'this page' : host} is for the user: ask them, or they can pick the files in the Preview.';
  }
  for (final f in files) {
    final abs = File(f.startsWith('/') ? f : '$root/$f').absolute.path;
    final real = FileSystemEntity.typeSync(abs) == FileSystemEntityType.notFound
        ? abs
        : File(abs).resolveSymbolicLinksSync();
    final r = Directory(root).existsSync() ? Directory(root).resolveSymbolicLinksSync() : root;
    if (!real.startsWith('$r/')) return 'Refused: $f is outside the project; upload only files from the project.';
    if (!File(real).existsSync()) return 'Error: $f does not exist.';
    if (secretPath(real)) return 'Refused: $f holds secrets or credentials; the agent never uploads those.';
  }
  return null;
}

/// Where the model's [x],[y] in frame [frame] (null: its latest) lands on [b]'s page. Before any screenshot the
/// point is taken as CSS pixels of the viewport, as the model may know them from the page itself.
Future<FramePoint> _point(BrowserPage b, String? frame, double x, double y) async {
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

/// Why the browser may not open [target] at all, from the agent or from the page (the Preview's "Open link in new
/// tab"): [_openRefusal] and the look-alike check of [browserTarget].
String? browserOpenRefusal(String target) => _openRefusal(target) ?? browserTarget(target).refusal;

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
void noteUserNavigation(BrowserPage b, String url) => _judged[b] = url;

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
