// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// The `app` tool's name, description and parameters: the same for the EveryAI harness and the host's MCP tool
// (outside leads).

const appToolName = 'app';

const appToolDescription =
    'See into and drive an app this session runs, through its framework: a Flutter app (`flutter run`, any device), '
    'a React Native app (Metro), or an Electron app (started with --remote-debugging-port=0). Start the app first '
    '(bash with run_in_background, or app_run); the tool finds it in that command\'s output. list shows what it '
    'found; source picks one when there are several (flutter, react-native, electron, a shell id, or the address '
    'the app printed, for an app started elsewhere).\n'
    '- action: list · look · snapshot · screenshot · zoom {x, y, width, height, frame?} · tap {ref, or x and y '
    'with frame} · long_press {ref} · type {ref, text, submit?: replaces the field\'s text} · submit · '
    'adjust {ref, steps: a slider\'s steps, negative for down} · drag {x, y, to_x, to_y, frame?} · '
    'scroll {dy, ref?} · back · home · reload · restart · logs · eval {script} · devices · boot {device} · install {path} · launch {bundle}.\n'
    '- snapshot is the element list: `[s12] button "Add"`, text fields with their values, plain text as `text '
    '"…"`. Tap and type by ref. look is a screenshot for a model that can see pictures, else the element list.\n'
    '- After tap, type, scroll and back the result says what changed on screen (text that appeared or went away); '
    'check it says what you expected.\n'
    '- Flutter: reload is hot reload (state kept), restart hot restart; eval runs a Dart expression in the app\'s '
    'main library (its top-level names are in scope; widget state is not). React Native: no screenshot here '
    '(look at the simulator or emulator), reload reloads the bundle, eval runs JavaScript. Electron: the browser '
    'tool\'s actions on the app\'s window. iOS Simulator (source "ios"): the simulator the app runs on, for any app '
    '(native, Flutter, React Native): its accessibility elements, screenshots, taps, typing and swipes, home; '
    'devices lists simulators, boot starts one headless, install puts a built .app on it, launch starts an app by '
    'bundle id (fresh). eval, reload, restart, logs and adjust don\'t apply there. One session drives a simulator at '
    'a time.\n'
    '- Every action reports what the app logged since the last one (prints, errors); logs reads it alone.\n'
    '- The user may take control in the Preview; your actions then wait until they give it back. It never types '
    'into password fields: the user does that.';

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
];

const appToolProperties = <String, Object?>{
  'action': {'type': 'string', 'enum': appToolActions},
  'source': {
    'type': 'string',
    'description': 'Which app: flutter, react-native, electron, ios, a shell id (bg_2), or an address it printed',
  },
  'ref': {'type': 'string', 'description': 'An element of the last element list (s12, r3, ref_4)'},
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
  'device': {'type': 'string', 'description': 'boot: a simulator name from devices (iPhone 16)'},
  'path': {'type': 'string', 'description': 'install: the built .app bundle'},
  'bundle': {'type': 'string', 'description': 'launch: the app\'s bundle id (com.example.app)'},
  'screenshot': {'type': 'boolean', 'description': 'Also return a screenshot after the action'},
  'snapshot': {'type': 'boolean', 'description': 'Also return the element list after the action'},
};
