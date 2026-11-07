// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Which apps a shell's output shows running, and where to reach them: the lines `flutter run`, Electron (any
// Chromium started with --remote-debugging-port) and Metro print when they start.

enum AppKind {
  flutter('Flutter'),
  reactNative('React Native'),
  electron('Electron'),
  ios('iOS Simulator');

  const AppKind(this.label);
  final String label;

  /// The name the `app` tool takes for it.
  String get id => switch (this) {
    flutter => 'flutter',
    reactNative => 'react-native',
    electron => 'electron',
    ios => 'ios',
  };
}

/// An app found in a shell's output: what it is and where its debugging endpoint is.
final class AppEndpoint {
  const AppEndpoint(this.kind, this.uri);
  final AppKind kind;

  /// Flutter: the VM service (`http://127.0.0.1:PORT/TOKEN=/`); Electron: the browser's DevTools socket
  /// (`ws://127.0.0.1:PORT/devtools/browser/ID`); React Native: Metro's server (`http://127.0.0.1:8081`); iOS
  /// Simulator: `simulator:<udid>`, or `simulator-name:<name>` for one an output names (resolved against the booted
  /// ones).
  final Uri uri;

  @override
  bool operator ==(Object other) => other is AppEndpoint && other.kind == kind && other.uri == uri;

  @override
  int get hashCode => Object.hash(kind, uri);

  @override
  String toString() => '${kind.label} at $uri';
}

final _ansi = RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])');

final _flutter = RegExp(
  r'(?:Dart VM [Ss]ervice on .*? is available at|The Dart VM service is listening on|Observatory listening on|'
  r'VM Service .*?(?:available|listening) (?:at|on)):?\s+(https?://[^\s]+)',
);
final _devtools = RegExp(r'DevTools listening on (wss?://[^\s]+/devtools/browser/[^\s]+)');
final _metro = RegExp(
  r'Welcome to Metro|Metro waiting on|Starting Metro Bundler|Starting dev server on|Waiting on http|'
  r'Logs for your project will appear below|Dev server ready',
);
final _metroPort = RegExp(
  r'(?:Metro waiting on|Waiting on|Starting dev server on|Metro.*?(?:on|at)|port)\s*:?\s*'
  r'(?:(?:https?|exp)://[^\s:/]+:)?(\d{2,5})',
);

/// The apps [output] (a shell's whole output so far, colours and all) shows starting, latest last; a kind seen
/// twice (a restart) keeps its latest endpoint only.
List<AppEndpoint> detectAppEndpoints(String output) {
  final text = output.replaceAll(_ansi, '').replaceAll('\r', '');
  final found = <AppKind, ({int at, Uri uri})>{};
  for (final m in _flutter.allMatches(text)) {
    var url = m.group(1)!;
    // The DevTools link printed right after carries the same address; the service URL ends with `=/`.
    url = url.replaceAll(RegExp(r'[).,]+$'), '');
    final uri = Uri.tryParse(url);
    if (uri != null && uri.hasPort) found[AppKind.flutter] = (at: m.start, uri: uri);
  }
  for (final m in _devtools.allMatches(text)) {
    final uri = Uri.tryParse(m.group(1)!);
    if (uri != null && uri.hasPort) found[AppKind.electron] = (at: m.start, uri: uri);
  }
  final metro = _metro.allMatches(text).lastOrNull;
  if (metro != null) {
    // The port on the banner's lines, else Metro's default.
    final after = text.substring(metro.start, (metro.start + 2000).clamp(0, text.length));
    final port = _metroPort.firstMatch(after)?.group(1) ?? _metroPort.firstMatch(text)?.group(1);
    final p = int.tryParse(port ?? '') ?? 8081;
    found[AppKind.reactNative] = (at: metro.start, uri: Uri.parse('http://127.0.0.1:${p > 0 && p < 65536 ? p : 8081}'));
  }
  final out = found.entries.toList()..sort((a, b) => a.value.at - b.value.at);
  return [
    for (final e in out) AppEndpoint(e.key, e.value.uri),
    for (final s in simulatorMentions(text)) AppEndpoint(AppKind.ios, s),
  ];
}

final _udid = RegExp(r'\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b');
final _runningOn = RegExp(r'\bon (iPhone[^\n]*?|iPad[^\n]*?) in (?:debug|profile|release) mode');
final _named = RegExp(
  r'''(?:-d|--device|--simulator|-destination)\s+['"]?(?:platform=iOS Simulator,name=)?((?:iPhone|iPad)[^'"\n,]*)''',
);

/// The simulators [text] names: udids (`simctl boot <udid>`, `-d <udid>`) as `simulator:<udid>`, device names
/// (`flutter run` "on iPhone 16 in debug mode", `-d "iPhone 16"`) as `simulator-name:<name>`.
List<Uri> simulatorMentions(String text) {
  final out = <String>{
    for (final m in _udid.allMatches(text)) 'simulator:${m.group(0)}',
    for (final m in [..._runningOn.allMatches(text), ..._named.allMatches(text)])
      'simulator-name:${Uri.encodeComponent(m.group(1)!.trim())}',
  };
  return [for (final s in out) Uri.parse(s)];
}
