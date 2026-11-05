// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

/// Desktop apps whose presence is worth an offer to set up their agent's CLI.
/// Finding one never makes a harness Ready: only the CLI does (`cliStateOf`).
enum DesktopApp {
  claude('Claude', 'claude-code'),
  cursor('Cursor', 'cursor'),
  antigravity('Antigravity', 'antigravity'),
  codexApp('Codex', 'codex'),
  vscode('Visual Studio Code', null);

  const DesktopApp(this.label, this.driverId);
  final String label;

  /// The registry id of the harness this app is the vendor's home for; null when
  /// the app only hosts agent extensions.
  final String? driverId;
}

/// What a scan found. [apps] maps an app to where it is (bundle, folder or
/// desktop file); [extensions] holds the ids of agent extensions in VS Code's
/// extension folder (`anthropic.claude-code`, `openai.chatgpt`, ...).
final class AppScan {
  const AppScan({this.apps = const {}, this.extensions = const {}});
  final Map<DesktopApp, String> apps;
  final Set<String> extensions;

  /// Whether to offer Set up for the harness [driverId]: its vendor's app is
  /// here, or (Claude Code, Codex) its VS Code extension is.
  bool offersSetUp(String driverId) {
    for (final a in apps.keys) {
      if (a.driverId == driverId) return true;
    }
    return switch (driverId) {
      'claude-code' => extensions.contains('anthropic.claude-code'),
      'codex' => extensions.contains('openai.chatgpt'),
      _ => false,
    };
  }
}

/// How each app shows up on disk. macOS: the bundle name. Windows: the folder
/// under `%LOCALAPPDATA%\Programs`, `Program Files` or the uninstall list.
/// Linux: the desktop file's `Name=`. The names of Cursor, Antigravity and the
/// Codex app are not checked against a real install yet. The "Claude Code URL
/// Handler" bundle Claude Code makes is a copy of the CLI and matches nothing.
const _names = <DesktopApp, List<String>>{
  DesktopApp.claude: ['Claude'],
  DesktopApp.cursor: ['Cursor'],
  DesktopApp.antigravity: ['Antigravity'],
  DesktopApp.codexApp: ['Codex'],
  DesktopApp.vscode: ['Visual Studio Code', 'Microsoft VS Code', 'Code'],
};

/// VS Code extensions that are coding agents; the rest of the folder is not reported.
const agentExtensions = {
  'anthropic.claude-code',
  'openai.chatgpt',
  'saoudrizwan.claude-dev',
  'rooveterinaryinc.roo-cline',
  'continue.continue',
  'github.copilot-chat',
  'google.geminicodeassist',
};

typedef ListDir = List<String> Function(String dir);

/// Looks for the apps in [_names] by their folder or file names: directory
/// listings only, plus the `Name=` line of a few Linux desktop files. It never
/// opens a config, cookie or token file. [os] is `macos`, `windows` or `linux`.
/// [listDir], [readFile] and [run] (for `reg query`) are for tests.
Future<AppScan> scanDesktopApps({
  required String os,
  required String home,
  required Map<String, String> env,
  required ListDir listDir,
  required String? Function(String path) readFile,
  required Future<String> Function(String executable, List<String> args) run,
}) async {
  final system = os;
  final e = env;
  final h = home;
  final list = listDir;
  final apps = <DesktopApp, String>{};

  void match(String dir, String sep) {
    for (final entry in list(dir)) {
      for (final MapEntry(key: app, value: names) in _names.entries) {
        if (!apps.containsKey(app) && names.contains(entry)) apps[app] = '$dir$sep$entry';
      }
    }
  }

  switch (system) {
    case 'macos':
      for (final dir in ['/Applications', '$h/Applications']) {
        for (final entry in list(dir)) {
          if (!entry.endsWith('.app')) continue;
          final name = entry.substring(0, entry.length - 4);
          for (final MapEntry(key: app, value: names) in _names.entries) {
            // Plain "Code" is a Windows/Linux name; on a Mac the bundle is "Visual Studio Code".
            if (!apps.containsKey(app) && names.contains(name) && name != 'Code') apps[app] = '$dir/$entry';
          }
        }
      }
    case 'windows':
      for (final dir in [
        if (e['LOCALAPPDATA'] case final l?) '$l\\Programs',
        ?e['ProgramFiles'],
        ?e['ProgramFiles(x86)'],
      ]) {
        match(dir, '\\');
      }
      if (apps.isEmpty) await _registry(apps, run);
    default:
      final read = readFile;
      for (final dir in [
        '/usr/share/applications',
        '$h/.local/share/applications',
        '/var/lib/flatpak/exports/share/applications',
        '$h/.local/share/flatpak/exports/share/applications',
        '/var/lib/snapd/desktop/applications',
      ]) {
        for (final entry in list(dir)) {
          if (!entry.endsWith('.desktop')) continue;
          final base = entry.toLowerCase();
          // Only files that could be one of ours are opened.
          if (!const ['claude', 'cursor', 'antigravity', 'codex', 'code', 'visual'].any(base.contains)) continue;
          final name = RegExp(r'^Name=(.+)$', multiLine: true).firstMatch(read('$dir/$entry') ?? '')?.group(1)?.trim();
          for (final MapEntry(key: app, value: names) in _names.entries) {
            if (!apps.containsKey(app) && name != null && names.contains(name)) apps[app] = '$dir/$entry';
          }
        }
      }
  }
  return AppScan(apps: apps, extensions: _extensionsIn(list, h, system == 'windows' ? '\\' : '/'));
}

/// The uninstall list (`reg query`), for an app installed somewhere unusual.
/// Only tried when the folders found nothing.
Future<void> _registry(Map<DesktopApp, String> apps, Future<String> Function(String, List<String>) run) async {
  const key = r'\Software\Microsoft\Windows\CurrentVersion\Uninstall';
  for (final hive in ['HKCU', 'HKLM']) {
    String out;
    try {
      out = await run('reg', ['query', '$hive$key', '/s', '/v', 'DisplayName']);
    } on Object {
      continue;
    }
    for (final m in RegExp(r'DisplayName\s+REG_SZ\s+(.+)').allMatches(out)) {
      // "Cursor (User)", "Microsoft Visual Studio Code": the name before any bracket.
      final shown = m.group(1)!.trim().replaceFirst(RegExp(r'\s*\(.*\)$'), '');
      for (final MapEntry(key: app, value: names) in _names.entries) {
        if (!apps.containsKey(app) &&
            shown != 'Code' &&
            (names.contains(shown) || (app == DesktopApp.vscode && shown == 'Microsoft Visual Studio Code'))) {
          apps[app] = '$hive registry';
        }
      }
    }
  }
}

/// `anthropic.claude-code-2.1.3-darwin-arm64` -> `anthropic.claude-code`.
String? extensionId(String folder) {
  final id = RegExp(r'^(.+?)-\d+\.\d+\.\d+').firstMatch(folder)?.group(1);
  return id != null && agentExtensions.contains(id) ? id : null;
}

Set<String> _extensionsIn(ListDir list, String home, String sep) => {
  for (final f in list('$home$sep.vscode${sep}extensions')) ?extensionId(f),
};

/// Numeric compare of dotted versions (2.1.10 > 2.1.9); a folder that does not
/// start with a version sorts last.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [for (final m in RegExp(r'\d+').allMatches(v.split('-').first)) int.parse(m.group(0)!)];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final c = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (c != 0) return c;
  }
  return 0;
}

/// Where a CLI that an installed app brought along may be, newest version first
/// and only files that exist. Claude's desktop app downloads Claude Code into
/// its own folder (checked on macOS); the VS Code extensions carry a native
/// binary (from their docs). The other paths are guesses: the caller starts
/// the file with `--version` before trusting it, so a wrong guess finds nothing.
List<String> bundledCliPaths(
  String command, {
  required String os,
  required String home,
  required Map<String, String> env,
  required ListDir listDir,
  required bool Function(String path) isFile,
}) {
  final system = os;
  final e = env;
  final h = home;
  final list = listDir;
  final exists = isFile;
  final win = system == 'windows';
  final sep = win ? '\\' : '/';
  final exe = win ? '$command.exe' : command;
  List<String> newest(String dir) => [...list(dir)]..sort((a, b) => compareVersions(b, a));

  final found = <String>[];
  if (command == 'claude') {
    final base = switch (system) {
      'macos' => '$h/Library/Application Support/Claude/claude-code',
      'windows' => '${e['APPDATA'] ?? '$h\\AppData\\Roaming'}\\Claude\\claude-code',
      _ => '$h/.config/Claude/claude-code',
    };
    for (final v in newest(base)) {
      for (final hash in list('$base$sep$v')) {
        found.add(
          system == 'macos' ? '$base/$v/$hash/claude.app/Contents/MacOS/claude' : '$base$sep$v$sep$hash$sep$exe',
        );
      }
    }
  }
  final extensions = '$h$sep.vscode${sep}extensions';
  final vendor = switch (command) {
    'claude' => 'anthropic.claude-code-',
    'codex' => 'openai.chatgpt-',
    _ => null,
  };
  if (vendor != null) {
    for (final f in newest(extensions).where((f) => f.startsWith(vendor))) {
      if (command == 'claude') {
        found.add('$extensions$sep$f${sep}resources${sep}native-binary$sep$exe');
      } else {
        for (final platform in list('$extensions$sep$f${sep}bin')) {
          found.add('$extensions$sep$f${sep}bin$sep$platform$sep$exe');
        }
      }
    }
  }
  return [
    for (final p in found)
      if (exists(p)) p,
  ];
}
