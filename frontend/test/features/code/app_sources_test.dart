// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:every_ai/features/code/harness/everyai/app_tools_io.dart';
import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/live/app_endpoints.dart';
import 'package:every_ai/features/code/live/app_sources.dart';
import 'package:every_ai/features/code/live/app_view.dart';
import 'package:every_ai/features/code/live/flutter_app_io.dart';
import 'package:every_ai/features/code/live/react_native_io.dart';
import 'package:every_ai/features/code/shells/shell_registry.dart';
import 'package:every_ai/features/code/shells/terminal_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('finding apps in shell output', () {
    test('flutter run, with colours and a restart: the latest VM service', () {
      const out =
          'Launching lib/main.dart on macOS in debug mode...\r\n'
          '\x1B[1mA Dart VM Service on macOS is available at: http://127.0.0.1:55175/1Fmm_xopQKs=/\x1B[0m\r\n'
          'The Flutter DevTools debugger and profiler on macOS is available at: '
          'http://127.0.0.1:55175/1Fmm_xopQKs=/devtools/?uri=ws://127.0.0.1:55175/1Fmm_xopQKs=/ws\r\n'
          'Lost connection to device.\r\n'
          'A Dart VM Service on macOS is available at: http://127.0.0.1:60001/abc=/\r\n';
      expect(detectAppEndpoints(out), [AppEndpoint(AppKind.flutter, Uri.parse('http://127.0.0.1:60001/abc=/'))]);
      expect(detectAppEndpoints('The Dart VM service is listening on http://127.0.0.1:8181/x_y=/'), [
        AppEndpoint(AppKind.flutter, Uri.parse('http://127.0.0.1:8181/x_y=/')),
      ]);
    });

    test('Electron and Metro, in the order they started', () {
      const out =
          ' BUNDLE  ./index.js\n'
          'Starting dev server on port 8082...\n'
          'Welcome to Metro v0.80.12\n'
          '\nDevTools listening on ws://127.0.0.1:9333/devtools/browser/5b1c-77\n';
      expect(detectAppEndpoints(out), [
        AppEndpoint(AppKind.reactNative, Uri.parse('http://127.0.0.1:8082')),
        AppEndpoint(AppKind.electron, Uri.parse('ws://127.0.0.1:9333/devtools/browser/5b1c-77')),
      ]);
      expect(detectAppEndpoints('Metro waiting on exp://192.168.1.5:8083\n'), [
        AppEndpoint(AppKind.reactNative, Uri.parse('http://127.0.0.1:8083')),
      ]);
      expect(detectAppEndpoints('Welcome to Metro\n Fast - Scalable - Integrated\n'), [
        AppEndpoint(AppKind.reactNative, Uri.parse('http://127.0.0.1:8081')),
      ]);
      expect(detectAppEndpoints('Compiling…\nnpm run dev\nready on http://localhost:3000'), isEmpty);
    });

    test('an address the agent gives: local only, its kind from its shape', () {
      expect(endpointFromUrl('http://127.0.0.1:55175/1Fmm=/')?.kind, AppKind.flutter);
      expect(endpointFromUrl('ws://127.0.0.1:55175/1Fmm=/ws')?.uri.toString(), 'http://127.0.0.1:55175/1Fmm=/');
      expect(endpointFromUrl('ws://localhost:9222/devtools/browser/abc')?.kind, AppKind.electron);
      expect(endpointFromUrl('http://localhost:8081')?.kind, AppKind.reactNative);
      expect(endpointFromUrl('http://example.com:8081'), isNull);
    });

    test('the session\'s shells are scanned; source picks among the apps', () {
      final e = _shell('pick', 'bg_3', 'flutter run -d macos');
      e.emit(_bytes('A Dart VM Service on macOS is available at: http://127.0.0.1:50000/t=/\r\n'));
      final other = _shell('pick', 'bg_4', 'npx react-native start');
      other.emit(_bytes('Welcome to Metro v0.80\r\n'));
      addTearDown(() => ShellRegistry.instance.forget('pick'));
      final apps = AppSources.running(['pick']);
      expect([for (final a in apps) a.kind], [AppKind.flutter, AppKind.reactNative]);
      expect(pickApp(apps, '')!.kind, AppKind.reactNative, reason: 'the newest');
      expect(pickApp(apps, 'flutter')!.shell!.id, 'bg_3');
      expect(pickApp(apps, 'bg_4')!.kind, AppKind.reactNative);
      expect(pickApp(apps, 'electron'), isNull);
      expect(appListText(apps), contains('flutter: Flutter app (bg_3: flutter run -d macos)'));
      expect(noAppText(const [], ''), contains('run_in_background'));
      expect(AppSources.running(['someone-else']), isEmpty);
    });

    test('an Electron call is the browser tool\'s', () {
      expect(electronArgs('look', const {}, vision: true)['action'], 'screenshot');
      expect(electronArgs('look', const {}, vision: false)['action'], 'snapshot');
      expect(electronArgs('tap', const {'ref': 'ref_2'}, vision: true), {'ref': 'ref_2', 'action': 'click'});
      expect(electronArgs('submit', const {}, vision: true), {'action': 'press', 'key': 'Enter'});
      expect(electronArgs('logs', const {}, vision: true)['action'], 'console');
    });
  });

  group('element lists', () {
    List<String> row(String id, String flags, String actions, {String label = '', String value = ''}) => [
      id,
      '30', '60', '330', '120', // physical pixels at 3×
      label, value, '', '', flags, actions,
    ];

    test('Flutter semantics rows become roles, states and logical places', () {
      final button = flutterNode(row('9', 'isButton,hasEnabledState,isEnabled', 'tap,focus', label: 'Add'), 3)!;
      expect(button.element(800, 600).line, '[s9] button "Add"');
      expect((button.left, button.top, button.right, button.bottom), (10.0, 20.0, 110.0, 40.0));
      final field = flutterNode(
        row('6', 'isTextField,isFocused,isFocusable', 'tap,setText', label: 'Name', value: 'Ada'),
        3,
      )!;
      expect(field.element(800, 600).line, '[s6] textbox "Name" value="Ada" (focused)');
      final pw = flutterNode(row('7', 'isTextField,isObscured', 'tap', label: 'Password', value: 'hunter2'), 3)!;
      expect(pw.element(800, 600).line, '[s7] textbox "Password" (password)');
      expect(pw.element(800, 600).line, isNot(contains('hunter2')));
      expect(
        flutterNode(row('10', 'hasCheckedState,isChecked,hasEnabledState', 'tap'), 3)!.element(800, 600).line,
        '[s10] checkbox (checked, disabled)',
      );
      expect(flutterNode(row('5', '', '', label: 'Count: 1'), 3)!.element(800, 600).line, 'text "Count: 1"');
      expect(
        flutterNode(row('8', 'hasEnabledState', '', label: 'Archived 0'), 3)!.element(800, 600).line,
        'text "Archived 0 (disabled)"',
      );
      expect(flutterNode(row('3', 'scopesRoute', ''), 3), isNull, reason: 'a container with nothing to show');
      expect(flutterNode(row('4', 'isHidden', 'tap', label: 'x'), 3), isNull);
      expect(
        flutterNode(row('22', 'hasImplicitScrolling', 'scrollUp,scrollToOffset'), 3)!.element(800, 600).line,
        '[s22] scrollable',
      );
    });

    test('what changed between two lists', () {
      const before = [
        AppNode(ref: '', role: 'text', name: 'Count: 0'),
        AppNode(ref: 's6', role: 'textbox', name: 'Name'),
        AppNode(ref: 's7', role: 'textbox', name: 'Password', value: 'a', secret: true),
      ];
      const after = [
        AppNode(ref: '', role: 'text', name: 'Count: 1'),
        AppNode(ref: 's6', role: 'textbox', name: 'Name', value: 'Ada'),
        AppNode(ref: 's7', role: 'textbox', name: 'Password', value: 'ab', secret: true),
      ];
      final change = appTreeChange(before, after)!;
      expect(change, contains('Changed: s6 textbox "Name" value="Ada"'));
      expect(change, contains('Now shown: text "Count: 1"'));
      expect(change, contains('No longer shown: text "Count: 0"'));
      expect(change, isNot(contains('No longer shown: text "Count: 0"; textbox')));
      expect(change, isNot(contains('Password')), reason: 'a secret field\'s value is not compared or shown');
      expect(appTreeChange(before, before), isNull);
      // A new page: what went is counted.
      final page = [for (var i = 0; i < 10; i++) AppNode(ref: '', role: 'text', name: 'Row $i')];
      final next = appTreeChange(page, const [AppNode(ref: 's1', role: 'heading', name: 'Note')])!;
      expect(
        next,
        'Now shown: heading "Note"\nNo longer shown: 10 items (a new page or a dialog over it, or scrolled away)',
      );
      expect(shortError(List.generate(20, (i) => 'line $i').join('\n')), endsWith('… (14 more lines of stack)'));
    });

    test('an off-screen control is listed apart; plain text off screen is not', () {
      const nodes = [
        AppNode(ref: 's1', role: 'button', name: 'Here', left: 0, top: 0, right: 10, bottom: 10),
        AppNode(ref: 's2', role: 'button', name: 'Below', left: 0, top: 900, right: 10, bottom: 910),
        AppNode(ref: '', role: 'text', name: 'Far text', left: 0, top: 900, right: 10, bottom: 910),
      ];
      expect(
        appTreeText('App', nodes, width: 800, height: 600),
        'App\n[s1] button "Here"\nOff screen (scroll to reach):\n[s2] button "Below"',
      );
    });

    test('Dart sources for the evaluator', () {
      expect(dartString("it's \$5\nok\\"), r"'it\'s \$5\nok\\'");
      expect(oneLineDart('a(\n  "http://x", // note\n  b) // end'), 'a( "http://x", b)');
    });
  });

  test('a terminal screen as text: where a full-screen program drew', () {
    const out =
        'starting\r\n'
        '\x1B[?1049h\x1B[2J\x1B[H  MENU\r\n\r\n  > Start\r\n    Quit\x1B[3;5H';
    final screen = terminalScreenText(out, rows: 10, columns: 40);
    expect(screen, startsWith('Screen (full-screen program, 40×10; cursor at row 3, column 5):'));
    expect(screen, contains('  MENU\n\n  > Start\n    Quit'));
    expect(screen, isNot(contains('starting')));
    expect(terminalScreenText('a\r\nb', rows: 5, columns: 20), contains('(terminal, 20×5; cursor at row 2, column 2)'));
  });

  group('with Chrome', () {
    final chrome = HeadlessBrowser.find();
    late Directory tmp;
    Process? proc;
    setUp(() => tmp = Directory.systemTemp.createTempSync('everyai-apps'));
    tearDown(() async {
      proc?.kill(ProcessSignal.sigkill);
      await proc?.exitCode;
      proc = null;
      ShellRegistry.instance.forget('apps');
      await AppSources.stopAll();
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Chrome may still hold its profile for a moment.
      }
    });

    /// Chrome on [html] with a DevTools port, as an Electron app would run; its stderr goes to shell [e].
    Future<Uri> startApp(String html, ShellEntry e) async {
      proc = await Process.start(chrome!, [
        '--headless=new',
        '--remote-debugging-port=0',
        '--user-data-dir=${tmp.path}/profile',
        '--no-first-run',
        '--window-size=800,600',
        'data:text/html,${Uri.encodeComponent(html)}',
      ]);
      final seen = Completer<Uri>();
      proc!.stderr.listen((b) {
        e.emit(Uint8List.fromList(b));
        final found = detectAppEndpoints(utf8.decode(b, allowMalformed: true));
        if (found.isNotEmpty && !seen.isCompleted) seen.complete(found.first.uri);
      });
      return seen.future.timeout(const Duration(seconds: 20));
    }

    test(
      'an Electron-style app is found in its shell and driven as a window',
      () async {
        final e = _shell('apps', 'bg_1', 'electron . --remote-debugging-port=0');
        await startApp(
          '<title>Desk</title><h1>Desk</h1><p id=s>idle</p>'
          '<button onclick="s.textContent=\'saved\';console.log(\'saved!\')">Save</button>',
          e,
        );
        Future<String> call(Map<String, Object?> args) async =>
            (await runAppTool(args, sessions: ['apps'], root: tmp.path, vision: false, fit: (t, _) => t)).text;
        expect(await call({'action': 'list'}), contains('electron: Electron app (bg_1'));
        final look = await call({'action': 'look'});
        expect(look, contains('button "Save"'));
        final ref = RegExp(r'\[(ref_\d+)\] button "Save"').firstMatch(look)!.group(1)!;
        final tapped = await call({'action': 'tap', 'ref': ref});
        expect(tapped, contains('button "Save"'));
        expect(tapped, contains('saved!'));
        expect(await call({'action': 'snapshot'}), contains('text "saved"'));
      },
      skip: chrome == null ? 'no Chrome here' : null,
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'React Native: Metro\'s target, the fiber walk, handlers, console, eval, reload',
      () async {
        final e = _shell('apps', 'bg_2', 'chrome');
        final devtools = await startApp('<title>RN</title><script>$_fakeReact</script>', e);
        // Chrome's page target stands in for Hermes behind a fake Metro.
        final page = await _pageSocket(devtools);
        final metro = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => metro.close(force: true));
        metro.listen((req) {
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode([
              {'title': 'React Native Bridgeless [C++ connection]', 'vm': 'Hermes', 'webSocketDebuggerUrl': page},
            ]),
          );
          unawaited(req.response.close());
        });
        final app = ReactNativeApp(Uri.parse('http://127.0.0.1:${metro.port}'));
        final listed = await app.snapshot();
        expect(listed, contains('text "Count: 0"'));
        expect(listed, contains('[r1] button "Add"'));
        expect(listed, contains('textbox "Email" value="a@b"'));
        expect(listed, contains('textbox "Password" (password)'));
        expect(listed, isNot(contains('hunter2')));
        final before = app.lastTree;
        expect(await app.tap('r1'), 'Tapped r1 button "Add".');
        await app.tree();
        expect(app.changedSince(before), contains('Now shown: text "Count: 1"'));
        final email = app.lastTree.firstWhere((n) => n.name == 'Email').ref;
        expect(await app.type(email, 'x@y', submit: true), contains('and submitted'));
        final pw = app.lastTree.firstWhere((n) => n.secret).ref;
        await expectLater(app.type(pw, 'z'), throwsA(isA<AppError>()));
        expect(app.takeLog(), containsAll(['console.log: text x@y', 'console.log: submit x@y']));
        expect(await app.evaluate('1 + 1'), '2');
        expect(await app.reload(), contains('Reloaded'));
        await app.close();
      },
      skip: chrome == null ? 'no Chrome here' : null,
      timeout: const Timeout(Duration(minutes: 1)),
    );
  });
}

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

ShellEntry _shell(String session, String id, String command) {
  final e = ShellEntry(
    key: '$session/$id',
    id: id,
    session: session,
    command: command,
    cwd: '/tmp',
    origin: ShellOrigin.agent,
    background: true,
  );
  ShellRegistry.instance.add(e);
  return e;
}

/// The page target's socket of the Chrome whose browser socket is [devtools].
Future<String> _pageSocket(Uri devtools) async {
  for (var i = 0; i < 50; i++) {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('http://${devtools.host}:${devtools.port}/json/list'));
      final list = jsonDecode(await (await req.close()).transform(utf8.decoder).join()) as List;
      final page = list.cast<Map<String, Object?>>().where((t) => t['type'] == 'page').firstOrNull;
      if (page != null) return page['webSocketDebuggerUrl']! as String;
    } finally {
      client.close(force: true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('no page');
}

/// A React-like fiber tree behind a DevTools hook, re-rendered on every state change (alternates linked).
const _fakeReact = r'''
let n = 0;
function F(tag, type, props, kids) {
  const f = {tag, type, memoizedProps: props, child: null, sibling: null, alternate: null};
  let prev = null;
  for (const k of kids || []) { if (prev) prev.sibling = k; else f.child = k; prev = k; }
  return f;
}
function T(s) { return F(6, null, s, []); }
function build() {
  return F(3, null, {}, [F(5, 'RCTView', {}, [
    F(5, 'RCTText', {}, [T('Count: '), T(String(n))]),
    F(1, 'TouchableOpacity', {onPress: () => { n++; render(); }}, [F(5, 'RCTView', {}, [F(5, 'RCTText', {}, [T('Add')])])]),
    F(11, 'TextInput', {placeholder: 'Email', value: 'a@b', onChangeText: (t) => console.log('text ' + t),
      onSubmitEditing: (e) => console.log('submit ' + e.nativeEvent.text)}, []),
    F(11, 'TextInput', {placeholder: 'Password', secureTextEntry: true, value: 'hunter2', onChangeText: () => console.log('BAD')}, []),
  ])]);
}
const root = {current: build()};
function link(a, b) { if (!a || !b) return; a.alternate = b; b.alternate = a; link(a.child, b.child); link(a.sibling, b.sibling); }
function render() { const old = root.current; root.current = build(); link(root.current, old); }
globalThis.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {renderers: new Map([[1, {}]]), getFiberRoots: () => new Set([root])};
''';
