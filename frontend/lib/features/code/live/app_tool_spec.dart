// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// The `app` tool's name, description and parameters: the same for the EveryAI harness and the host's MCP tool
// (outside leads).

const appToolName = 'app';

const appToolDescription =
    'See into and drive an app this session runs, through its framework: a Flutter app (`flutter run`, any device), '
    'a React Native app (Metro), or an Electron app (started with --remote-debugging-port=<a free port>; '
    'electron-vite: --remoteDebuggingPort <port>, which drops 0). Start the app first '
    '(bash with run_in_background, or app_run); the tool finds it in that command\'s output. list shows what it '
    'found; source picks one when there are several (flutter, react-native, electron, a shell id, or the address '
    'the app printed, for an app started elsewhere).\n'
    '- action: list · look · snapshot · screenshot · zoom {x, y, width, height, frame?} · tap {ref, or x and y '
    'with frame} · long_press {ref} · type {ref, text, submit?: replaces the field\'s text} · submit · '
    'adjust {ref, steps: a slider\'s steps, negative for down} · drag {x, y, to_x, to_y, frame?} · '
    'scroll {dy, ref?} · back · home · reload · restart · logs · eval {script} · key {key} · devices · boot {device} · install {path} · launch {bundle} · '
    'logins · fill_login {login, field: username | password | code, ref, submit?}.\n'
    '- snapshot is the element list: `[s12] button "Add"`, text fields with their values, plain text as `text '
    '"…"`. Tap and type by ref. look is a screenshot for a model that can see pictures, else the element list.\n'
    '- After tap, type, scroll and back the result says what changed on screen (text that appeared or went away); '
    'check it says what you expected.\n'
    '- Flutter: reload is hot reload (state kept), restart hot restart; eval runs a Dart expression in the app\'s '
    'main library (its top-level names are in scope; widget state is not). React Native: no screenshot here '
    '(look at the simulator or emulator), reload reloads the bundle, eval runs JavaScript. Electron: the browser '
    'tool\'s actions on the app\'s window (its renderer console; the main process logs to its shell). Device screens, for any app on them (native, Flutter, React Native): an '
    'iOS Simulator (source "ios", coordinates in points) or an Android emulator or device (source "android", '
    'pixels): accessibility elements, screenshots, taps, typing and swipes, back, home. devices lists them, boot '
    'starts one headless, install puts a built app on it (.app, .apk), launch starts one fresh (bundle: its bundle '
    'id or package). logs is logcat of the app in front on Android; eval, reload, restart and adjust don\'t apply to '
    'device screens. One session drives a device at a time.\n'
    '- Desktop windows (source "desktop", macOS): any app this session started or built here that has a window. '
    'Accessibility first, in the background: tap presses an element (a list entry: selects its row), type sets a '
    'text field, scroll uses its scroll bar, long_press opens its menu. What accessibility can\'t do (taps at x '
    'and y on apps with no elements such as Tk, games and canvases; key {key: "Enter", "cmd+s"}; drag; the wheel) '
    'uses the real pointer and keyboard: the window comes to the front, and the user is asked once whether that is '
    'allowed. Screenshots show the window with its pop-ups and dialogs. window: a title when it has several.\n'
    '- Every action reports what the app logged since the last one (prints, errors); logs reads it alone.\n'
    '- Signing in: logins lists the logins the user saved for you (name, site, username; the values stay hidden), '
    'and fill_login types one by name into the field ref: username, password, or code (the current authenticator '
    'code, when the login has one). When the user asks you to sign in, do it. A one-time code sent by text message '
    'or email needs the user: ask them for it. Some users keep password fields to fill_login only; type then says '
    'so.\n'
    '- The user may take control in the Preview; your actions then wait until they give it back.';

const appToolActions = [
  'list',
  'look',
  'snapshot',
  'screenshot',
  'zoom',
  'tap',
  'long_press',
  'type',
  'submit',
  'key',
  'adjust',
  'drag',
  'scroll',
  'back',
  'home',
  'reload',
  'restart',
  'logs',
  'eval',
  'devices',
  'boot',
  'install',
  'launch',
  'logins',
  'fill_login',
];

const appToolProperties = <String, Object?>{
  'action': {'type': 'string', 'enum': appToolActions},
  'source': {
    'type': 'string',
    'description':
        'Which app: flutter, react-native, electron, ios, android, desktop, a shell id (bg_2), or an address it '
        'printed',
  },
  'ref': {'type': 'string', 'description': 'An element of the last element list (s12, r3, ref_4)'},
  'login': {'type': 'string', 'description': 'fill_login: the name of a saved login (logins lists them)'},
  'field': {
    'type': 'string',
    'enum': ['username', 'password', 'code'],
    'description': 'fill_login: which value to type (default password)',
  },
  'frame': {'type': 'string', 'description': 'The screenshot (f_N) that x and y are in'},
  'x': {'type': 'number'},
  'y': {'type': 'number'},
  'width': {'type': 'number'},
  'height': {'type': 'number'},
  'text': {'type': 'string'},
  'submit': {'type': 'boolean'},
  'dy': {'type': 'number', 'description': 'Pixels to scroll; positive is down'},
  'to_x': {'type': 'number'},
  'to_y': {'type': 'number'},
  'steps': {'type': 'integer', 'description': "adjust: the slider's steps to move (negative: down)"},
  'script': {'type': 'string'},
  'device': {
    'type': 'string',
    'description':
        'boot: a name from devices (iPhone 16, Pixel_9_API_36). With source ios or android: which running device '
        'to drive when several are',
  },
  'key': {'type': 'string', 'description': 'key: a key or shortcut (Enter, Escape, Tab, cmd+s, ctrl+a)'},
  'window': {'type': 'string', 'description': 'desktop: which window, by (part of) its title'},
  'count': {
    'type': 'integer',
    'description': 'tap on a desktop window: 2 double-clicks, 3 triple-clicks (selects a field\'s text to type over)',
  },
  'path': {'type': 'string', 'description': 'install: the built app (.app for iOS, .apk for Android)'},
  'bundle': {'type': 'string', 'description': 'launch: the bundle id (iOS) or package (Android), com.example.app'},
  'screenshot': {'type': 'boolean', 'description': 'Also return a screenshot after the action'},
  'snapshot': {'type': 'boolean', 'description': 'Also return the element list after the action'},
};
