// ignore_for_file: invalid_use_of_visible_for_testing_member
// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Dev only: the OS webview backend, live. Serves a few local pages, embeds the session browser's view as the Preview
// does, drives it through the agent's browser tool (runBrowser) step by step, and writes what happened (and the
// pictures) to RIG_OUT. Real clicks and keys for the watch-only check go through the AX helper (EVERYAI_AX_HELPER,
// posted to this app's process only).
//   flutter run -d macos -t tool/live_apps/webview_rig.dart --dart-define=RIG_OUT=/tmp/rig \
//     --dart-define=AX_HELPER=/path/to/everyai-ax
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/harness/everyai/screen_tools_io.dart';
import 'package:every_ai/features/code/live/agent_logins.dart';
import 'package:every_ai/features/code/live/browser_jar.dart';
import 'package:every_ai/features/code/live/browser_page.dart';
import 'package:every_ai/features/code/live/live_browsers.dart';
import 'package:every_ai/features/code/live/webview_browser.dart';
import 'package:every_ai/features/code/live/webview_model.dart';
import 'package:every_ai/features/code/ui/panes/browser_logins.dart' show fillPageWithLogin;
import 'package:every_ai/features/code/ui/panes/browser_overlays.dart';
import 'package:every_ai/features/code/ui/panes/preview_apps.dart' show LiveDriverBar;
import 'package:every_ai/features/code/ui/panes/webview_page_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _outDefine = String.fromEnvironment('RIG_OUT');
const _axDefine = String.fromEnvironment('AX_HELPER');

final _shown = ValueNotifier<WebviewBrowser?>(null);
final _viewKey = GlobalKey();
late final Directory _out;
final _lines = <String>[];

void _note(String line) {
  _lines.add(line);
  // ignore: avoid_print
  print('RIG $line');
  File('${_out.path}/results.txt').writeAsStringSync('${_lines.join('\n')}\n');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _out = Directory(_outDefine.isNotEmpty ? _outDefine : (Platform.environment['RIG_OUT'] ?? '/tmp/webview-rig'))
    ..createSync(recursive: true);
  final theme = EveryTheme.resolve(DesignLanguage.macos, Brightness.dark);
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: EveryThemeScope(
        theme: theme,
        child: ColoredBox(
          color: theme.background,
          child: ValueListenableBuilder<WebviewBrowser?>(
            valueListenable: _shown,
            builder: (context, b, _) => b == null
                ? const Center(child: Text('Preview closed'))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LiveDriverBar(control: b.control),
                      BrowserTabStrip(browser: b),
                      Expanded(
                        child: KeyedSubtree(
                          key: _viewKey,
                          child: WebviewPageView(browser: b, focus: _focus, device: null, ghost: null),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    ),
  );
  unawaited(_run().catchError((Object e, StackTrace s) => _note('RIG CRASHED: $e\n$s')).whenComplete(() => exit(0)));
}

final _focus = FocusNode();

Future<HttpServer> _serve() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final r = req.response;
    final path = req.uri.path;
    final cookie = req.cookies.where((c) => c.name == 'sid').firstOrNull?.value;
    void html(String body) {
      r.headers.contentType = ContentType.html;
      r.write('<!doctype html><meta charset="utf-8">$body');
    }

    switch (path) {
      case '/form':
        html('''<title>Form</title>
<form id="f"><input id="name" name="name"><input id="email" name="email">
<select id="fruit"><option value="a">Apple</option><option value="b">Banana</option></select>
<input id="pw" type="password"><div id="note" contenteditable="true" style="min-height:20px;border:1px solid #888"></div>
<button id="submit" type="submit">Send</button></form>
<p id="out"></p><p id="subs">0</p>
<script>
let subs = 0;
document.getElementById('f').addEventListener('submit', (e) => { e.preventDefault(); subs++;
  document.getElementById('subs').textContent = subs;
  const v = (id) => document.getElementById(id);
  v('out').textContent = [v('name').value, v('fruit').value, v('note').innerText].join('|'); });
</script>''');
      case '/long':
        html('<title>Long</title><div style="height:4000px;background:linear-gradient(#fff,#08f)">top</div>');
      case '/timer':
        html(
          '''<title>Timer</title><p id="n">0</p><button id="pop" onclick="window.open('/timer?child=1')">Pop</button>
<a id="blank" href="/timer?blank=1" target="_blank">New tab</a> <button id="close" onclick="window.close()">Close</button>
<script>window.n = 0; window.t0 = Date.now(); setInterval(() => { n++; document.getElementById('n').textContent = n; }, 100);</script>''',
        );
      case '/dialogs':
        html('''<title>Dialogs</title><button id="a" onclick="alert('hi'); out.textContent='alerted'">A</button>
<button id="c" onclick="out.textContent = String(confirm('sure?'))">C</button>
<button id="p" onclick="out.textContent = prompt('name?', 'x')">P</button><p id="out"></p>''');
      case '/files':
        html('''<title>Files</title><a id="dl" href="/file.txt">Download</a>
<input id="file" type="file" onchange="out.textContent = [...this.files].map(f => f.name + ':' + f.size).join(',')">
<p id="out"></p>''');
      case '/file.txt':
        r.headers.set('content-disposition', 'attachment; filename="report.txt"');
        r.headers.contentType = ContentType.text;
        r.write('downloaded body ${cookie ?? 'nocookie'}');
      case '/login':
        html('''<title>Sign in</title><form method="post" action="/do-login">
<input id="user" name="user" autocomplete="username"><input id="pw" name="pw" type="password">
<button id="go">Sign in</button></form>''');
      case '/do-login':
        final body = await utf8.decoder.bind(req).join();
        final q = Uri.splitQueryString(body);
        if (q['user'] == 'ada' && q['pw'] == 'correct-horse-77') {
          r.headers.add('set-cookie', 'sid=ada-session; Path=/; HttpOnly');
        }
        r.statusCode = 303;
        r.headers.set('location', '/me');
      case '/me':
        html('<title>Me</title><p id="who">${cookie == null ? 'signed out' : 'signed in as $cookie'}</p>');
      case '/watch':
        html(
          '''<title>Watch</title><input id="t" style="width:400px;height:60px;font-size:30px" autofocus>
<p id="c">0</p><p id="m">0</p><script>let c = 0, m = 0; addEventListener('mousedown', (e) => { if (e.isTrusted) c++; document.getElementById('c').textContent = c; });
addEventListener('mousemove', (e) => { if (e.isTrusted) m++; document.getElementById('m').textContent = m; });</script>''',
        );
      default:
        r.statusCode = 404;
    }
    await r.close();
  });
  return server;
}

Future<void> _run() async {
  final server = await _serve();
  final base = 'http://127.0.0.1:${server.port}';
  final root = Directory('${_out.path}/root')..createSync(recursive: true);
  final sealed = SealedStore('${_out.path}/sealed', () async => SecretKey(List.filled(32, 7)));
  JarHome home(String name) => (store: () async => sealed, name: name);
  final a = WebviewBrowser(jarHome: home('jar-a'));
  final logins = AgentLogins(SealedStore('${_out.path}/logins', () async => SecretKey(List.filled(32, 9))));
  await logins.save(
    name: 'local',
    url: '$base/login',
    username: 'ada',
    password: 'correct-horse-77',
    scope: LoginScope.global,
  );
  final access = LoginAccess(policy: const LoginPolicy(), logins: () async => logins);
  var shots = 0;

  Future<String> tool(BrowserPage b, Map<String, Object?> args, {LoginAccess? guard}) async {
    final o = await runBrowser(
      b,
      args,
      root: root.path,
      vision: false,
      fit: (t, _) => t,
      logins: guard ?? access,
      loginHold: const Duration(seconds: 2),
    );
    return '${o.isError ? 'ERROR ' : ''}${o.text}';
  }

  Future<Object?> js(BrowserPage b, String s) => b.evaluate(s);
  var step = 0;
  Future<void> check(String name, Future<String?> Function() body) async {
    step++;
    final sw = Stopwatch()..start();
    try {
      final problem = await body();
      _note('STEP $step $name: ${problem == null ? 'OK' : 'FAIL: $problem'} (${sw.elapsedMilliseconds} ms)');
    } on Object catch (e) {
      _note('STEP $step $name: FAIL (threw) $e');
    }
  }

  Future<void> shot(WebviewBrowser b, String name) async {
    final (png, f) = await b.frameShot();
    File('${_out.path}/${++shots}-$name.png').writeAsBytesSync(png);
    _note('  picture ${f.id} ${f.imageWidth}×${f.imageHeight} → $shots-$name.png (png ${pngSize(png)})');
  }

  // This app's window in front (as when the user works in it); later steps also run with it behind.
  final ax0 = _axDefine.isNotEmpty ? _axDefine : Platform.environment['EVERYAI_AX_HELPER'];
  if (ax0 != null) {
    await Process.run(ax0, ['raise', '--pid', '$pid']);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    _note('window: ${(await Process.run(ax0, ['windows', '--pid', '$pid'])).stdout}'.trim());
  }
  await const MethodChannel('everyai/webview').invokeMethod<void>('debug', {'on': true});
  // The Preview shows A from the start.
  _shown.value = a;
  await check('open a form (shown in the Preview)', () async {
    final r = await tool(a, {'action': 'open', 'url': '$base/form'});
    _note('  $r'.split('\n').take(6).join('\n  '));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final tab = a.activeWebTab!;
    return r.contains('Form') && tab.life == TabLife.shown ? null : 'tab life ${tab.life}, result $r';
  });
  await check('type into a text field by selector', () async {
    await tool(a, {'action': 'type', 'selector': '#name', 'text': 'Ada Lovelace'});
    final v = await js(a, 'document.getElementById("name").value');
    return v == 'Ada Lovelace' ? null : 'value $v';
  });
  await check('pick a select option by typing its text', () async {
    final r = await tool(a, {'action': 'type', 'selector': '#fruit', 'text': 'Banana'});
    final v = await js(a, 'document.getElementById("fruit").value');
    return v == 'b' ? null : 'value $v ($r)';
  });
  await check('type into contenteditable', () async {
    await tool(a, {'action': 'type', 'selector': '#note', 'text': 'hello note'});
    final v = await js(a, 'document.getElementById("note").innerText.trim()');
    return v == 'hello note' ? null : 'text $v';
  });
  await check('guarded type into a password field is refused', () async {
    final strict = LoginAccess(policy: const LoginPolicy(secretFields: false), logins: () async => logins);
    final r = await tool(a, {'action': 'type', 'selector': '#pw', 'text': 'x'}, guard: strict);
    return r.contains('Refused: the field is a password field') ? null : r;
  });
  await check('click the submit button', () async {
    final r = await tool(a, {'action': 'click', 'selector': '#submit'});
    final v = await js(a, 'document.getElementById("out").textContent');
    return v == 'Ada Lovelace|b|hello note' ? null : 'out $v ($r)';
  });
  await check('press Tab moves the focus; Enter submits', () async {
    await tool(a, {'action': 'click', 'selector': '#name'});
    final r = await tool(a, {'action': 'press', 'key': 'Tab'});
    final f = await js(a, 'document.activeElement.id');
    await tool(a, {'action': 'press', 'key': 'Enter'});
    final subs = await js(a, 'document.getElementById("subs").textContent');
    return f == 'email' && subs == '2' ? null : 'focus $f, submits $subs ($r)';
  });
  await check('press characters and Backspace', () async {
    await tool(a, {'action': 'click', 'selector': '#email'});
    for (final k in ['a', '@', 'b', 'x', 'Backspace']) {
      await tool(a, {'action': 'press', 'key': k});
    }
    final v = await js(a, 'document.getElementById("email").value');
    return v == 'a@b' ? null : 'value $v';
  });
  await check('screenshot (frame) while shown', () async {
    await shot(a, 'form-shown');
    return null;
  });
  await check('scroll', () async {
    await tool(a, {'action': 'open', 'url': '$base/long'});
    final r = await tool(a, {'action': 'scroll', 'dy': 900});
    final y = await js(a, 'scrollY');
    return (y as num) > 0 ? null : 'scrollY $y ($r)';
  });
  await check('eval in the page world (statements and a promise)', () async {
    final v1 = await js(a, 'const q = 2; q * 21');
    final v2 = await js(a, 'new Promise(r => setTimeout(() => r("later"), 50))');
    return v1 == 42 && v2 == 'later' ? null : '$v1 / $v2';
  });

  // Tabs: a pop-up and a target=_blank link, each a live tab.
  await check('a pop-up becomes a tab; tabs keep ticking whichever is shown', () async {
    await tool(a, {'action': 'open', 'url': '$base/timer'});
    await tool(a, {'action': 'click', 'selector': '#pop'});
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final tabs = a.tabs.value;
    if (tabs.length != 2) return '${tabs.length} tabs';
    final second = a.activeTab!;
    // Ticks per second of each tab over a span it spent hidden (a 100 ms timer: 10 a second unthrottled).
    Future<({num n, num t})> read() async {
      final v = await js(a, '[n, Date.now()]') as List;
      return (n: v[0] as num, t: v[1] as num);
    }

    final c1 = await read();
    await a.switchTab(tabs.first.id);
    final p1 = await read();
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final v = await a.debugEvaluateIn(second, '[n, document.visibilityState, document.hasFocus()]');
      _note('  pop-up hidden ${i + 1} s: $v (${a.tabsDebug})');
    }
    final p2 = await read();
    await a.switchTab(second);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final c2 = await read();
    await shot(a, 'popup-tab');
    final opener = (p2.n - p1.n) * 1000 / (p2.t - p1.t), popup = (c2.n - c1.n) * 1000 / (c2.t - c1.t);
    _note(
      '  opener (shown) ${opener.toStringAsFixed(1)}/s; pop-up (hidden ~4.5 s) ${popup.toStringAsFixed(1)}/s; '
      'pop-up tab is ${a.activeWebTab?.life}',
    );
    return opener >= 8 && popup >= 8 ? null : 'opener $opener/s, pop-up $popup/s';
  });
  await check('target=_blank link opens a tab; window.close returns to the opener', () async {
    await a.switchTab(a.tabs.value.first.id);
    await tool(a, {'action': 'click', 'selector': '#blank'});
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final n = a.tabs.value.length;
    final url = await js(a, 'location.href');
    await tool(a, {'action': 'click', 'selector': '#close'});
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final after = a.tabs.value.length;
    final here = await js(a, 'location.href');
    return n == 3 && '$url'.contains('blank=1') && after == 2 && !'$here'.contains('blank=1')
        ? null
        : 'tabs $n → $after; new $url, now $here';
  });
  await check('a call to a closed tab throws TabClosedError', () async {
    final id = a.tabs.value.last.id;
    final t = a.activeWebTab;
    await a.switchTab(id);
    final pending = a.evaluate('new Promise((r) => setTimeout(r, 3000))');
    // The call is on its way to the tab before it closes.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await a.closeTab(id);
    try {
      await pending;
      return 'no error ($t)';
    } on TabClosedError {
      return null;
    } on BrowserError catch (e) {
      return 'BrowserError $e';
    }
  });
  await check('the Preview closes: the page keeps running offscreen (parked) and takes pictures', () async {
    final tab = a.activeWebTab!;
    final n1 = await js(a, 'n') as num;
    _shown.value = null;
    await Future<void>.delayed(const Duration(seconds: 2));
    final n2 = await js(a, 'n') as num;
    await shot(a, 'parked');
    _note('  tab ${tab.id} is ${tab.life}; ticked ${n2 - n1} in 2 s offscreen');
    return tab.life == TabLife.parked && n2 - n1 >= 15 ? null : '${tab.life}, ${n2 - n1} ticks';
  });
  await check('the Preview opens again on the same live page (no reload)', () async {
    final before = await js(a, 'n') as num;
    _shown.value = a;
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final after = await js(a, 'n') as num;
    final tab = a.activeWebTab!;
    return tab.life == TabLife.shown && after >= before ? null : '${tab.life}, n $before → $after';
  });

  // Dialogs.
  await check('alert: the call ends saying so; the dialog is answered', () async {
    await tool(a, {'action': 'open', 'url': '$base/dialogs'});
    final r = await tool(a, {'action': 'click', 'selector': '#a'});
    final d = a.dialog.value;
    final ans = await tool(a, {'action': 'dialog', 'accept': true});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final out = await js(a, 'out.textContent');
    _note('  click: ${r.split('\n').first}\n  answer: ${ans.split('\n').first}');
    return d?.type == 'alert' && out == 'alerted' ? null : 'dialog $d, out $out';
  });
  await check('confirm dismissed, prompt answered', () async {
    await tool(a, {'action': 'click', 'selector': '#c'});
    await tool(a, {'action': 'dialog', 'accept': false});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final c = await js(a, 'out.textContent');
    await tool(a, {'action': 'click', 'selector': '#p'});
    await tool(a, {'action': 'dialog', 'accept': true, 'text': 'Zed'});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final p = await js(a, 'out.textContent');
    return c == 'false' && p == 'Zed' ? null : 'confirm $c, prompt $p';
  });

  // Files.
  await check('a download lands in the download folder', () async {
    await tool(a, {'action': 'open', 'url': '$base/files'});
    final r = await tool(a, {'action': 'click', 'selector': '#dl'});
    final d = a.downloads.value.lastOrNull;
    final body = d?.path == null ? null : File(d!.path!).readAsStringSync();
    _note('  ${r.split('\n').take(3).join(' / ')}');
    return d?.state == 'completed' && body != null && body.startsWith('downloaded body') ? null : 'download $d';
  });
  await check('upload sets files on the input', () async {
    File('${root.path}/hello.txt').writeAsStringSync('hello upload');
    final r = await tool(a, {
      'action': 'upload',
      'selector': '#file',
      'files': ['hello.txt'],
    });
    final out = await js(a, 'out.textContent');
    return out == 'hello.txt:12' ? null : 'out $out ($r)';
  });
  await check('a click on a file input opens no picker for the agent', () async {
    final r = await tool(a, {'action': 'click', 'selector': '#file'});
    final chooser = a.fileChooser.value;
    a.cancelFileChooser();
    return chooser != null && r.contains('file picker opened') ? null : 'chooser $chooser: $r';
  });

  // Sign-in with a saved login, cookies, isolation, the jar.
  await check('fill_login signs in (username, password, submit)', () async {
    await tool(a, {'action': 'open', 'url': '$base/login'});
    final u = await tool(a, {'action': 'fill_login', 'login': 'local', 'field': 'username', 'selector': '#user'});
    final p = await tool(a, {'action': 'fill_login', 'login': 'local', 'selector': '#pw', 'submit': true});
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final who = await js(a, 'document.getElementById("who") && document.getElementById("who").textContent');
    final leaked = [u, p, ...a.history].any((s) => s.contains('correct-horse-77'));
    _note('  ${u.split('\n').first}\n  ${p.split('\n').first}');
    return who == 'signed in as ada-session' && !leaked ? null : 'who $who, leaked $leaked';
  });
  await check('the HttpOnly session cookie is in the jar', () async {
    final jar = await a.captureJar();
    final sid = jar.cookies.where((c) => c['name'] == 'sid').firstOrNull;
    return sid != null && sid['httpOnly'] == true ? null : 'cookies ${jar.cookies}';
  });
  final b = WebviewBrowser(jarHome: home('jar-b'));
  await check('another session on the same site is signed out (isolation)', () async {
    await tool(b, {'action': 'open', 'url': '$base/me'});
    final who = await js(b, 'document.getElementById("who").textContent');
    final sid = (await b.captureJar()).cookies.where((c) => c['name'] == 'sid');
    return who == 'signed out' && sid.isEmpty ? null : 'B sees $who';
  });
  await check('the jar round trip: a new browser on A\'s jar starts signed in', () async {
    await a.saveJar();
    final c = WebviewBrowser(jarHome: home('jar-a'));
    await tool(c, {'action': 'open', 'url': '$base/me'});
    final who = await js(c, 'document.getElementById("who").textContent');
    await c.close();
    return who == 'signed in as ada-session' ? null : 'C sees $who';
  });
  await check('signing out of the site clears it', () async {
    await a.clearJar(site: '127.0.0.1');
    await tool(a, {'action': 'open', 'url': '$base/me'});
    final who = await js(a, 'document.getElementById("who").textContent');
    return who == 'signed out' ? null : 'A sees $who';
  });
  await b.close();

  // Checked again right before typing: a page that left the login's site while the Allow card waited gets nothing.
  await check('fill_login after a redirect during the Allow wait types nothing (own site only)', () async {
    final gate = LoginGate.of('rig-redirect');
    final strict = LoginAccess(
      policy: const LoginPolicy(withoutAsking: false, anySite: false),
      logins: () async => logins,
      gate: gate,
    );
    await tool(a, {'action': 'open', 'url': '$base/login'});
    final pending = tool(a, {'action': 'fill_login', 'login': 'local', 'selector': '#pw'}, guard: strict);
    for (var i = 0; i < 50 && gate.stateOf('local') is! ConsentAsking; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // localhost is another site to a login for 127.0.0.1.
    await js(a, 'location.href = "http://localhost:${server.port}/login"');
    for (var i = 0; i < 50 && await js(a, 'location.hostname') != 'localhost'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    gate.answer('local', allow: true);
    final r = await pending;
    final pw = await js(a, 'document.getElementById("pw").value');
    _note('  ${r.split('\n').first}');
    return r.contains('this page is on localhost') && pw == '' ? null : 'pw "$pw": $r';
  });
  await check("the Preview key menu's fill is blanked in a later eval", () async {
    LiveBrowsers.debugSet('rig-a', a);
    await tool(a, {'action': 'open', 'url': '$base/login'});
    await fillPageWithLogin(a, logins.entries.value.single, logins);
    final r = await tool(a, {
      'action': 'eval',
      'script': 'document.getElementById("pw").value',
    }, guard: LoginAccess(logins: () async => logins, gate: LoginGate.of('rig-a')));
    final typed = await js(a, 'document.getElementById("pw").value');
    LiveBrowsers.debugSet('rig-a', null);
    return typed == 'correct-horse-77' && !r.contains('correct-horse-77') && r.contains('EVERYAI-HIDDEN')
        ? null
        : 'typed ${typed == 'correct-horse-77'}, result $r';
  });

  // Watch-only, with real clicks and keys posted to this app.
  final ax = _axDefine.isNotEmpty ? _axDefine : Platform.environment['EVERYAI_AX_HELPER'];
  if (ax == null || !File(ax).existsSync()) {
    _note('STEP watch-only: SKIPPED (no AX helper)');
  } else {
    await tool(a, {'action': 'open', 'url': '$base/watch'});
    await Future<void>.delayed(const Duration(milliseconds: 600));
    Future<({double x, double y})> screenPoint() async {
      final r = await Process.run(ax, ['windows', '--pid', '$pid']);
      final w = (jsonDecode('${r.stdout}') as List).cast<Map<String, Object?>>().first;
      final box = _viewKey.currentContext!.findRenderObject()! as RenderBox;
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final contentTop = (w['h']! as num) - view.physicalSize.height / view.devicePixelRatio;
      final at = box.localToGlobal(Offset(box.size.width / 2, 60));
      return (x: (w['x']! as num) + at.dx, y: (w['y']! as num) + contentTop + at.dy);
    }

    // Whether the helper sent the click (it refuses where another app's window is over the point).
    Future<bool> click() async {
      final p = await screenPoint();
      // A real click (the helper posts it only where this app's window is on top, and waits while the user is busy):
      // a click posted to the process carries no window, which WebKit drops.
      var r = await Process.run(ax, ['click', '--pid', '$pid', '--x', '${p.x}', '--y', '${p.y}', '--front']);
      // Something of the user's over that point (exit 7): wait for it to go, a few times.
      for (var i = 0; i < 5 && r.exitCode == 7; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        r = await Process.run(ax, ['click', '--pid', '$pid', '--x', '${p.x}', '--y', '${p.y}', '--front']);
      }
      _note('  click at (${p.x.round()}, ${p.y.round()}): exit ${r.exitCode} ${r.stdout}${r.stderr}'.trim());
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return r.exitCode == 0;
    }

    Future<void> keys(String text) async {
      await Process.run(ax, ['key', '--pid', '$pid', '--text', text]);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }

    // Posted clicks go to the key window: bring this app's window to the front (no input is posted for that).
    await Process.run(ax, ['raise', '--pid', '$pid']);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await check('watch-only: a real click and keys don\'t reach the page while the agent has it', () async {
      final hints = a.control.takeHints.value;
      final sent = await click();
      await keys('zz');
      final c = await js(a, 'document.getElementById("c").textContent');
      final v = await js(a, 'document.getElementById("t").value');
      final hinted = a.control.takeHints.value - hints;
      _note('  page clicks $c, field "$v", Take control hints $hinted${sent ? '' : ' (click not sent: keys only)'}');
      return c == '0' && v == '' && hinted > 0 ? null : 'clicks $c, field "$v", hints $hinted';
    });
    // Moves the real pointer over the view (the helper's scroll with no distance moves the pointer there first);
    // false when the helper sent nothing (another app's window over the point, or the user busy).
    Future<bool> hover() async {
      final p = await screenPoint();
      var sent = 0;
      for (final dx in [0, 40, 80]) {
        final args = ['--x', '${p.x + dx}', '--y', '${p.y}', '--dy', '0', '--front'];
        final r = await Process.run(ax, ['scroll', '--pid', '$pid', ...args]);
        if (r.exitCode == 0) sent++;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      _note('  pointer moves sent: $sent of 3');
      return sent > 0;
    }

    await check('watch-only: the pointer moving over the page gives it no hover', () async {
      final before = await js(a, 'document.getElementById("m").textContent');
      final sent = await hover();
      final after = await js(a, 'document.getElementById("m").textContent');
      if (!sent) return 'not checked: the pointer was not moved (another window over the point)';
      return before == after ? null : 'mousemove $before → $after';
    });
    await check('Take control: the same click and keys reach the page natively', () async {
      a.control.take();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final sent = await click();
      await keys('ok');
      final c = await js(a, 'document.getElementById("c").textContent');
      final v = await js(a, 'document.getElementById("t").value');
      _note('  page clicks $c, field "$v"${sent ? '' : ' (click not sent: keys only)'}');
      return (c == '1' || !sent) && v == 'ok' ? null : 'clicks $c, field "$v"';
    });
    await check('with control, the pointer moving over the page hovers it', () async {
      final before = int.tryParse('${await js(a, 'document.getElementById("m").textContent')}') ?? 0;
      if (!await hover()) return 'not checked: the pointer was not moved (another window over the point)';
      final after = int.tryParse('${await js(a, 'document.getElementById("m").textContent')}') ?? 0;
      return after > before ? null : 'mousemove $before → $after';
    });
    await check('Give back: the keyboard leaves the page again', () async {
      a.control.giveBack();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await keys('nope');
      final v = await js(a, 'document.getElementById("t").value');
      return v == 'ok' ? null : 'field "$v"';
    });
  }
  await shot(a, 'final');
  await a.close();
  _note('refused moves: ${a.refusedMoves}');
  _note('DONE');
  await server.close(force: true);
}
