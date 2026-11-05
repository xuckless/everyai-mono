// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'bridges.dart';
import 'exec_env.dart';
import 'path_maps.dart';
import 'shell_quote.dart';

/// What a finished command gave: its exit code and raw stdout (raw, since
/// `wsl -l` answers in UTF-16).
typedef CommandResult = ({int code, List<int> stdout});

/// Runs a host CLI (an absolute path) with the login shell's environment
/// plus [environment]. Null when it couldn't start or didn't finish within
/// [timeout], in which case it was killed.
typedef RunCommand = Future<CommandResult?> Function(
  String executable,
  List<String> args, {
  Duration timeout,
  Map<String, String> environment,
});

enum HostOs { macos, linux, windows, other }

/// What discovery needs from this computer, injectable for tests.
final class EnvironmentIo {
  const EnvironmentIo({
    required this.run,
    required this.which,
    required this.os,
    this.home = '',
    this.readFile = _noFile,
    this.exists = _noPath,
    this.listDir = _noDir,
    this.wslEnv = '',
  });

  final RunCommand run;

  /// A CLI's absolute path on the login shell's PATH, or null.
  final Future<String?> Function(String command) which;
  final HostOs os;
  final String home;
  final String? Function(String path) readFile;
  final bool Function(String path) exists;
  final List<String> Function(String dir) listDir;

  /// The user's own WSLENV (Windows).
  final String wslEnv;

  static String? _noFile(String _) => null;
  static bool _noPath(String _) => false;
  static List<String> _noDir(String _) => const [];
}

/// The environments found, the host first, then WSL, containers, VMs and
/// SSH remotes; and per kind (`wsl`, `docker`, `lima`, `orb`, `multipass`,
/// `colima`, `ssh`) what went wrong, in plain words.
final class EnvDiscovery {
  const EnvDiscovery(this.environments, [this.problems = const {}]);

  final List<ExecEnv> environments;
  final Map<String, String> problems;
}

/// Thrown by a kind's discovery to give its problem text.
final class _Problem implements Exception {
  const _Problem(this.message);
  final String message;
}

/// Looks for every kind whose CLI is on this computer, all at once, each
/// call capped at [timeout]. Nothing is installed or started; a kind that
/// fails only adds its problem. ssh remotes come from [sshEnvironments].
Future<EnvDiscovery> discoverEnvironments(EnvironmentIo io, {Duration timeout = const Duration(seconds: 3)}) async {
  final kinds = <String, Future<List<ExecEnv>> Function()>{
    'wsl': () => _wsl(io, timeout),
    'docker': () => _docker(io, timeout),
    'lima': () => _lima(io, timeout),
    'orb': () => _orb(io, timeout),
    'multipass': () => _multipass(io, timeout),
    'colima': () => _colima(io, timeout),
  };
  final results = await Future.wait([
    for (final find in kinds.values)
      () async {
        try {
          return (await find(), null);
        } on _Problem catch (e) {
          return (const <ExecEnv>[], e.message);
        } on Object catch (e) {
          return (const <ExecEnv>[], 'Something went wrong: $e');
        }
      }(),
  ]);
  final names = kinds.keys.toList();
  return EnvDiscovery(
    [HostEnv.instance, for (final (envs, _) in results) ...envs],
    {
      for (var i = 0; i < results.length; i++)
        if (results[i].$2 != null) names[i]: results[i].$2!,
    },
  );
}

String _text(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

List<String> _lines(String text) => [
  for (final l in const LineSplitter().convert(text))
    if (l.trim().isNotEmpty) l.trim(),
];

/// JSON objects from NDJSON (one per line) or one JSON array.
List<Map<String, Object?>> _objects(String text) {
  final t = text.trim();
  if (t.isEmpty) return const [];
  Object? whole;
  try {
    whole = jsonDecode(t);
  } on FormatException {
    whole = null;
  }
  if (whole is List) {
    return [
      for (final o in whole)
        if (o is Map<String, Object?>) o,
    ];
  }
  if (whole is Map<String, Object?>) return [whole];
  final out = <Map<String, Object?>>[];
  for (final line in _lines(t)) {
    try {
      final o = jsonDecode(line);
      if (o is Map<String, Object?>) out.add(o);
    } on FormatException {
      // Not JSON (a warning line): skipped.
    }
  }
  return out;
}

// ---- WSL ----

/// The distro names in `wsl.exe -l -q` output: UTF-16LE (with a BOM, or NULs
/// at odd offsets) unless the CLI answered in UTF-8. Docker Desktop's own
/// distros are left out.
List<String> decodeWslOutput(List<int> bytes) {
  String text;
  final bom = bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE;
  var wide = bom;
  for (var i = 1; !wide && i < bytes.length; i += 2) {
    if (bytes[i] == 0) wide = true;
  }
  if (wide) {
    final start = bom ? 2 : 0;
    final units = <int>[for (var i = start; i + 1 < bytes.length; i += 2) bytes[i] | bytes[i + 1] << 8];
    text = String.fromCharCodes(units);
  } else {
    text = _text(bytes);
  }
  return [
    for (final l in _lines(text.replaceAll('﻿', '').replaceAll('\x00', '')))
      if (!l.toLowerCase().startsWith('docker-desktop')) l,
  ];
}

Future<List<ExecEnv>> _wsl(EnvironmentIo io, Duration timeout) async {
  if (io.os != HostOs.windows) return const [];
  final cli = await io.which('wsl.exe');
  if (cli == null) return const [];
  const utf16 = {'WSL_UTF8': '0'};
  final all = await io.run(cli, const ['-l', '-q'], timeout: timeout, environment: utf16);
  if (all == null) throw const _Problem("WSL didn't answer.");
  // A non-zero exit: no distros installed.
  if (all.code != 0) return const [];
  final up = await io.run(cli, const ['-l', '-q', '--running'], timeout: timeout, environment: utf16);
  final running = up != null && up.code == 0 ? decodeWslOutput(up.stdout).toSet() : const <String>{};
  return [
    for (final d in decodeWslOutput(all.stdout))
      if (safeName(d)) WslEnv(cli: cli, distro: d, running: running.contains(d), inheritedWslEnv: io.wslEnv),
  ];
}

// ---- Docker and dev containers ----

/// Local context names from `docker context ls --format '{{json .}}'`, the
/// current one first; contexts on the same endpoint as an earlier one are
/// dropped (they list the same containers). Contexts on another machine
/// (`ssh://`, `tcp://`) are left out: discovery never connects to a machine
/// the user didn't add, and their bind mounts aren't this computer's folders.
List<String> parseDockerContexts(String text) {
  final all = _objects(text)..sort((a, b) => (b['Current'] == true ? 1 : 0) - (a['Current'] == true ? 1 : 0));
  final endpoints = <String>{};
  return [
    for (final c in all)
      if (c['Name'] case final String name when safeName(name))
        if (c['DockerEndpoint'] case final Object? e when e == null || '$e'.startsWith(RegExp('unix://|npipe://')))
          if (endpoints.add('${e ?? name}')) name,
  ];
}

/// The last `remoteUser` in a `devcontainer.metadata` label (a JSON array of
/// the merged configs, or one object).
String? devcontainerUser(String? metadata) {
  if (metadata == null) return null;
  Object? json;
  try {
    json = jsonDecode(metadata);
  } on FormatException {
    return null;
  }
  String? user;
  for (final entry in json is List ? json : [json]) {
    if (entry is Map && entry['remoteUser'] is String) user = entry['remoteUser'] as String;
  }
  return user != null && safeName(user) ? user : null;
}

/// Running containers from `docker inspect` output.
List<DockerEnv> parseDockerInspect(String json, {required String cli, String? context, String? hostName}) {
  final out = <DockerEnv>[];
  for (final c in _objects(json)) {
    final id = c['Id'], rawName = c['Name'];
    if (id is! String || !safeName(id)) continue;
    final state = c['State'];
    if (state is Map && state['Running'] == false) continue;
    final name = rawName is String && rawName.isNotEmpty
        ? (rawName.startsWith('/') ? rawName.substring(1) : rawName)
        : id.substring(0, id.length.clamp(0, 12));
    final config = c['Config'];
    final labels = config is Map && config['Labels'] is Map ? config['Labels'] as Map : const <String, Object?>{};
    final mounts = <Mount>[
      for (final m in c['Mounts'] is List ? c['Mounts'] as List : const [])
        if (m is Map && m['Type'] == 'bind' && m['Source'] is String && m['Destination'] is String)
          (host: m['Source'] as String, env: m['Destination'] as String, writable: m['RW'] != false),
    ];
    final folder = labels['devcontainer.local_folder'];
    out.add(
      DockerEnv(
        cli: cli,
        container: id.substring(0, id.length.clamp(0, 12)),
        name: name,
        context: context,
        user: folder is String ? devcontainerUser(labels['devcontainer.metadata'] as String?) : null,
        devcontainerFolder: folder is String && folder.isNotEmpty ? folder : null,
        mounts: MountMap(mounts),
        hostName: hostName,
      ),
    );
  }
  return out;
}

Future<List<ExecEnv>> _docker(EnvironmentIo io, Duration timeout) async {
  final cli = await io.which('docker');
  if (cli == null) return const [];
  final listed = await io.run(cli, const ['context', 'ls', '--format', '{{json .}}'], timeout: timeout);
  final known = listed != null && listed.code == 0;
  final contexts = <String?>[if (known) ...parseDockerContexts(_text(listed.stdout))];
  // Only contexts on other machines: nothing local to list.
  if (known && contexts.isEmpty && _objects(_text(listed.stdout)).isNotEmpty) return const [];
  if (contexts.isEmpty) contexts.add(null);
  final hostName = io.os == HostOs.linux ? null : 'host.docker.internal';
  var answered = 0;
  final found = await Future.wait([
    for (final ctx in contexts)
      () async {
        final prefix = [
          if (ctx != null) ...['--context', ctx],
        ];
        final ps = await io.run(cli, [...prefix, 'ps', '-q'], timeout: timeout);
        if (ps == null || ps.code != 0) return const <DockerEnv>[];
        answered++;
        final ids = _lines(_text(ps.stdout)).where(safeName).toList();
        if (ids.isEmpty) return const <DockerEnv>[];
        final inspect = await io.run(cli, [...prefix, 'inspect', ...ids], timeout: timeout);
        if (inspect == null || inspect.code != 0) return const <DockerEnv>[];
        return parseDockerInspect(_text(inspect.stdout), cli: cli, context: ctx, hostName: hostName);
      }(),
  ]);
  if (answered == 0) throw const _Problem("Docker isn't running, or didn't answer.");
  // Two contexts can reach one daemon by different paths (Docker Desktop's
  // `default` and `desktop-linux`): one entry per container, the current
  // context's.
  final seen = <String>{};
  final all = [
    for (final list in found)
      for (final e in list)
        if (seen.add(e.container)) e,
  ];
  // Dev containers first: they belong to a project.
  return [...all.where((e) => e.devcontainerFolder != null), ...all.where((e) => e.devcontainerFolder == null)];
}

/// Why the project at [projectPath] can't use its dev container, or null:
/// it has a `.devcontainer` config but no running container was made for
/// it. The app never starts one.
String? devcontainerProblem(
  String projectPath,
  List<ExecEnv> environments, {
  required bool Function(String path) exists,
  bool windows = false,
}) {
  final sep = windows ? '\\' : '/';
  final has =
      exists('$projectPath$sep.devcontainer${sep}devcontainer.json') || exists('$projectPath$sep.devcontainer.json');
  if (!has) return null;
  String norm(String p) {
    final t = p.endsWith(sep) && p.length > 1 ? p.substring(0, p.length - 1) : p;
    return windows ? t.toLowerCase() : t;
  }

  final running = environments.whereType<DockerEnv>().any(
    (e) => e.devcontainerFolder != null && norm(e.devcontainerFolder!) == norm(projectPath),
  );
  return running
      ? null
      : "This project's dev container isn't running. Start it (in VS Code, or with devcontainer up), then check again.";
}

// ---- Linux VMs ----

String _expandHome(String path, String home) =>
    path == '~' ? home : (path.startsWith('~/') ? '$home${path.substring(1)}' : path);

/// Lima instances from `limactl list --json` (one JSON object per line).
/// Colima's own instances (`colima`, `colima-<profile>`) are left out; they
/// come as Colima. Without mount data the home folder is assumed shared
/// read-only (Lima's default).
List<LimaEnv> parseLimaList(String text, {required String cli, required String home}) => [
  for (final o in _objects(text))
    if (o['name'] case final String name when safeName(name) && !name.startsWith('colima'))
      LimaEnv(cli: cli, name: name, home: home, running: o['status'] == 'Running', mounts: _limaMounts(o, home)),
];

MountMap _limaMounts(Map<String, Object?> o, String home) {
  final config = o['config'];
  final raw = config is Map && config['mounts'] is List ? config['mounts'] : o['mounts'];
  if (raw is! List) return MountMap([(host: home, env: home, writable: false)]);
  return MountMap([
    for (final m in raw)
      if (m is Map && m['location'] is String)
        (
          host: _expandHome(m['location'] as String, home),
          env: _expandHome((m['mountPoint'] as String?) ?? (m['location'] as String), home),
          writable: m['writable'] == true,
        ),
  ]);
}

/// OrbStack machines as (name, running), from `orbctl list --format json`
/// (an array, or `{machines: […]}`), or from the plain table `orb list`
/// prints (NAME STATE … columns).
List<(String, bool)> parseOrbList(String text) {
  final t = text.trim();
  Object? json;
  try {
    json = jsonDecode(t);
  } on FormatException {
    json = null;
  }
  final list = json is Map ? json['machines'] : json;
  if (list is List) {
    return [
      for (final m in list)
        if (m is Map && m['name'] is String && safeName(m['name'] as String))
          (m['name'] as String, '${m['state'] ?? m['status']}'.toLowerCase() == 'running'),
    ];
  }
  if (json != null) return const [];
  return [
    for (final line in _lines(t))
      if (line.split(RegExp(r'\s+')) case [final name, final state, ...] when name != 'NAME' && safeName(name))
        (name, state.toLowerCase() == 'running'),
  ];
}

/// Multipass instances as (name, running), from `multipass list --format
/// json` (`{list: [{name, state}]}`).
List<(String, bool)> parseMultipassList(String text) {
  final o = _objects(text);
  final list = o.isEmpty ? null : o.first['list'];
  return [
    if (list is List)
      for (final m in list)
        if (m is Map && m['name'] is String && safeName(m['name'] as String))
          (m['name'] as String, m['state'] == 'Running'),
  ];
}

/// Each instance's shares from `multipass info --format json`
/// (`{info: {name: {mounts: {target: {source_path}}}}}`).
Map<String, MountMap> parseMultipassMounts(String text) {
  final o = _objects(text);
  final info = o.isEmpty ? null : o.first['info'];
  if (info is! Map) return const {};
  return {
    for (final MapEntry(:key, :value) in info.entries)
      if (key is String && value is Map)
        key: MountMap([
          if (value['mounts'] case final Map<String, Object?> mounts)
            for (final MapEntry(key: target, value: m) in mounts.entries)
              if (m is Map && m['source_path'] is String)
                (host: m['source_path'] as String, env: target, writable: true),
        ]),
  };
}

/// Colima profiles as (name, running), from `colima list --json` (one JSON
/// object per line: name, status, runtime).
List<(String, bool)> parseColimaList(String text) => [
  for (final o in _objects(text))
    if (o['name'] case final String name when safeName(name)) (name, o['status'] == 'Running'),
];

Future<String> _listed(EnvironmentIo io, String cli, List<String> args, Duration timeout, String what) async {
  final r = await io.run(cli, args, timeout: timeout);
  if (r == null) throw _Problem("$what didn't answer.");
  if (r.code != 0) throw _Problem("$what couldn't list its machines.");
  return _text(r.stdout);
}

Future<List<ExecEnv>> _lima(EnvironmentIo io, Duration timeout) async {
  if (io.os != HostOs.macos && io.os != HostOs.linux) return const [];
  final cli = await io.which('limactl');
  if (cli == null) return const [];
  return parseLimaList(await _listed(io, cli, const ['list', '--json'], timeout, 'Lima'), cli: cli, home: io.home);
}

Future<List<ExecEnv>> _orb(EnvironmentIo io, Duration timeout) async {
  if (io.os != HostOs.macos) return const [];
  final orb = await io.which('orb');
  final orbctl = await io.which('orbctl');
  final lister = orbctl ?? orb;
  if (lister == null) return const [];
  // Any other orb command starts OrbStack when it's quit; `status` doesn't.
  final status = await io.run(lister, const ['status'], timeout: timeout);
  if (status == null || _text(status.stdout).trim().toLowerCase() != 'running') {
    throw const _Problem("OrbStack isn't running. Open it to use its machines, then check again.");
  }
  final json = await io.run(lister, const ['list', '--format', 'json'], timeout: timeout);
  final text = json != null && json.code == 0
      ? _text(json.stdout)
      : await _listed(io, lister, const ['list'], timeout, 'OrbStack');
  return [
    for (final (name, running) in parseOrbList(text))
      OrbEnv(cli: orb ?? orbctl!, machine: name, home: io.home, running: running, viaOrbctl: orb == null),
  ];
}

Future<List<ExecEnv>> _multipass(EnvironmentIo io, Duration timeout) async {
  final cli = await io.which('multipass');
  if (cli == null) return const [];
  final vms = parseMultipassList(await _listed(io, cli, const ['list', '--format', 'json'], timeout, 'Multipass'));
  final up = [
    for (final (name, running) in vms)
      if (running) name,
  ];
  final info = up.isEmpty ? null : await io.run(cli, ['info', '--format', 'json', ...up], timeout: timeout);
  final mounts = info != null && info.code == 0 ? parseMultipassMounts(_text(info.stdout)) : const <String, MountMap>{};
  return [
    for (final (name, running) in vms)
      MultipassEnv(cli: cli, name: name, running: running, mounts: mounts[name] ?? const MountMap([])),
  ];
}

Future<List<ExecEnv>> _colima(EnvironmentIo io, Duration timeout) async {
  if (io.os != HostOs.macos && io.os != HostOs.linux) return const [];
  final cli = await io.which('colima');
  if (cli == null) return const [];
  return [
    for (final (name, running) in parseColimaList(await _listed(io, cli, const ['list', '--json'], timeout, 'Colima')))
      ColimaEnv(cli: cli, profile: name, home: io.home, running: running),
  ];
}

// ---- SSH remotes ----

/// Preferences key of the remotes the user added: `{v: 1, remotes: [{alias}
/// | {user, host, port?}]}`.
const sshRemotesKey = 'code.environments.ssh';

List<SshRemote> readSshRemotes(String? raw) {
  if (raw == null) return const [];
  try {
    final json = jsonDecode(raw);
    final list = json is Map ? json['remotes'] : null;
    return [
      if (list is List)
        for (final r in list) ?SshRemote.fromJson(r),
    ];
  } on FormatException {
    return const [];
  }
}

String encodeSshRemotes(List<SshRemote> remotes) => jsonEncode({
  'v': 1,
  'remotes': [for (final r in remotes) r.toJson()],
});

/// The ssh remotes the user added as environments, given ssh's path on this
/// computer ([cli], null when it isn't installed). Nothing is run: a remote
/// is only reached when it's scanned.
EnvDiscovery sshEnvironments(List<SshRemote> remotes, {required String? cli}) {
  if (remotes.isEmpty) return const EnvDiscovery([]);
  if (cli == null) return const EnvDiscovery([], {'ssh': "ssh isn't installed on this computer."});
  return EnvDiscovery([
    for (final r in remotes)
      if (r.problem == null) SshEnv(cli: cli, remote: r),
  ]);
}

/// The `Host` names in an ssh config [text], to suggest in the add form:
/// patterns (`*`, `?`, `!`) are skipped, and `Include` files are read one
/// level deep ([read] a file, [list] a folder's entries; relative paths are
/// in [sshDir], `~/` is [home]).
List<String> sshConfigHosts(
  String text, {
  String? Function(String path)? read,
  List<String> Function(String dir)? list,
  String sshDir = '',
  String home = '',
}) {
  final out = <String>[];
  void scan(String text, {required bool includes}) {
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final m = RegExp(r'^(\S+?)(?:\s*=\s*|\s+)(.*)$').firstMatch(line);
      if (m == null) continue;
      final words = m.group(2)!.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
      switch (m.group(1)!.toLowerCase()) {
        case 'host':
          for (final w in words) {
            if (!RegExp(r'[*?!]').hasMatch(w) && safeName(w) && !out.contains(w)) out.add(w);
          }
        case 'include' when includes && read != null:
          for (final w in words) {
            for (final file in _globFiles(_expandHome(w, home), sshDir, list)) {
              final included = read(file);
              if (included != null) scan(included, includes: false);
            }
          }
      }
    }
  }

  scan(text, includes: true);
  return out;
}

/// The files an Include pattern names: `*` and `?` in the last segment only.
List<String> _globFiles(String pattern, String sshDir, List<String> Function(String dir)? list) {
  final path = pattern.startsWith('/') ? pattern : '$sshDir/$pattern';
  final cut = path.lastIndexOf('/');
  final dir = path.substring(0, cut), name = path.substring(cut + 1);
  if (!RegExp(r'[*?]').hasMatch(name)) return [path];
  final re = RegExp('^${name.split('').map((c) => c == '*' ? '.*' : (c == '?' ? '.' : RegExp.escape(c))).join()}\$');
  return [
    for (final entry in ((list ?? (_) => const <String>[])(dir).toList()..sort()))
      if (re.hasMatch(entry)) '$dir/$entry',
  ];
}
