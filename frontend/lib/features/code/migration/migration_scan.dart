// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../agents/domain/agent_definition.dart' show agentEfforts, agentNamePattern, parseAgentMode;
import '../../skills/domain/hidden_instructions.dart' show scanInstructions;
import '../../slash/custom/custom_command.dart';
import '../domain/agent_mode.dart' show AgentMode;
import '../domain/mcp_servers.dart';
import '../settings/context_files.dart' show contextFileNames;

// "Bring over from other tools": what other tools' config files hold, read into plain items the user ticks. Pure
// Dart (no files, no providers) so every mapping is testable; migration_files.dart reads, migration_providers.dart
// writes. Nothing here runs a command or expands an environment variable.

enum ImportKind {
  mcp('MCP servers'),
  command('Custom commands'),
  agent('Agents'),
  skill('Skills'),
  rule('Rules files');

  const ImportKind(this.label);
  final String label;
}

/// One thing found in another tool's files.
@immutable
final class ImportItem {
  const ImportItem({
    required this.kind,
    required this.source,
    required this.title,
    this.scope,
    this.detail = '',
    this.notes = const [],
    this.unavailable,
    this.checked = true,
    this.mcp,
    this.command,
    this.agentName,
    this.agentText,
    this.path,
    this.used = false,
  });

  final ImportKind kind;

  /// The tool it came from ("Claude Code"); several joined by ", " when the same server is in more.
  final String source;
  final String title;

  /// The project folder it belongs to, or null for the tool's own (user-level) config.
  final String? scope;

  /// One line of what it is (the command line, the URL, the description).
  final String detail;

  /// What was left out or needs a look, in plain words.
  final List<String> notes;

  /// Why it can't be brought over (also "Already in EveryAI"); such a row has no checkbox.
  final String? unavailable;

  /// Whether the row starts ticked.
  final bool checked;

  final McpServer? mcp;
  final CustomCommand? command;
  final String? agentName;
  final String? agentText;

  /// The skill folder or the rules file.
  final String? path;

  /// A rules file EveryAI already reads.
  final bool used;

  bool get selectable => unavailable == null && kind != ImportKind.rule;

  ImportItem copyWith({String? source, String? unavailable, bool? checked, McpServer? mcp, List<String>? notes}) =>
      ImportItem(
        kind: kind,
        source: source ?? this.source,
        title: title,
        scope: scope,
        detail: detail,
        notes: notes ?? this.notes,
        unavailable: unavailable ?? this.unavailable,
        checked: checked ?? this.checked,
        mcp: mcp ?? this.mcp,
        command: command,
        agentName: agentName,
        agentText: agentText,
        path: path,
        used: used,
      );
}

const toolClaude = 'Claude Code';
const toolCursor = 'Cursor';
const toolCodex = 'Codex';
const toolOpenCode = 'OpenCode';

// ---------------------------------------------------------------------------------------------------- MCP servers

/// A name the store accepts ([McpServer.namePattern]).
String mcpName(String raw) {
  var s = raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-').replaceFirst(RegExp(r'^[^A-Za-z0-9]+'), '');
  if (s.length > 40) s = s.substring(0, 40);
  return s.isEmpty ? 'server' : s;
}

final _variable = RegExp(r'\$\{|\$[A-Za-z_]|%[A-Za-z_]+%');

Map<String, String> _strMap(Object? v) => {
  if (v is Map<String, Object?>)
    for (final e in v.entries)
      if (e.value is String) e.key: e.value! as String,
};

List<String> _strList(Object? v) => [
  if (v is List<Object?>)
    for (final a in v)
      if (a is String) a,
];

/// Builds the row for one server entry. [type] is already worked out by the caller; [dropped] names the fields of
/// the entry that have no home here.
ImportItem _mcpItem({
  required String tool,
  required String name,
  required String? scope,
  required McpTransport? transport,
  String command = '',
  List<String> args = const [],
  Map<String, String> env = const {},
  String url = '',
  Map<String, String> headers = const {},
  bool enabled = true,
  List<String> dropped = const [],
  String? unsupported,
}) {
  final notes = <String>[];
  final safe = mcpName(name);
  if (safe != name) notes.add('Renamed from "$name".');
  if (transport == null) {
    return ImportItem(
      kind: ImportKind.mcp,
      source: tool,
      title: safe,
      scope: scope,
      unavailable: unsupported ?? "Can't be brought over.",
    );
  }
  final all = [command, ...args, url, ...env.values, ...headers.values];
  final hasVariables = all.any(_variable.hasMatch);
  if (hasVariables) {
    notes.add("Uses variables EveryAI doesn't fill in, so it comes over switched off. Edit it in MCP servers.");
  }
  if (dropped.isNotEmpty) notes.add("Left out (no equivalent): ${dropped.join(', ')}.");
  final server = McpServer(
    name: safe,
    transport: transport,
    command: command,
    args: args,
    env: env,
    url: url,
    headers: headers,
    enabled: enabled && !hasVariables,
    description: 'Imported from $tool',
  );
  final flags = reviewMcpServer(server);
  final blocked = flags.where((f) => f.level == McpFlagLevel.blocked).firstOrNull;
  final risky = flags.any((f) => f.level == McpFlagLevel.danger || f.level == McpFlagLevel.warning);
  final secret = RegExp(r'key|token|secret|password|auth', caseSensitive: false);
  final carriesSecret =
      env.keys.any(secret.hasMatch) || headers.keys.any(secret.hasMatch) || url.contains(RegExp(r'[?&](key|token)='));
  if (carriesSecret) notes.add('Carries a key or token in its settings; it is copied as it is.');
  return ImportItem(
    kind: ImportKind.mcp,
    source: tool,
    title: safe,
    scope: scope,
    detail: transport == McpTransport.stdio ? server.commandLine : url,
    notes: [...notes, for (final f in flags.where((f) => f.level != McpFlagLevel.blocked)) f.text],
    unavailable: server.problem ?? (blocked == null ? null : 'Blocked: ${blocked.text}'),
    checked: scope == null && !hasVariables && !risky && !carriesSecret,
    mcp: server,
  );
}

McpTransport? _remoteKind(String? type) => switch (type) {
  null || '' || 'http' || 'streamable-http' || 'streamableHttp' || 'remote' => McpTransport.http,
  'sse' => McpTransport.sse,
  _ => null,
};

/// A JSON value as text, or null when it is anything else (the files are other tools' and may be malformed).
String? _str(Object? v) => v is String ? v : null;

List<ImportItem> _claudeServers(Object? servers, String? scope, String tool) {
  if (servers is! Map<String, Object?>) return const [];
  final out = <ImportItem>[];
  for (final e in servers.entries) {
    final v = e.value;
    if (v is! Map<String, Object?>) continue;
    final type = _str(v['type']);
    final dropped = [
      for (final k in const ['headersHelper', 'oauth', 'cwd', 'timeout', 'envFile'])
        if (v.containsKey(k)) k,
    ];
    if (type == 'stdio' || (type == null && v['url'] is! String)) {
      out.add(
        _mcpItem(
          tool: tool,
          name: e.key,
          scope: scope,
          transport: McpTransport.stdio,
          command: _str(v['command']) ?? '',
          args: _strList(v['args']),
          env: _strMap(v['env']),
          dropped: dropped,
        ),
      );
    } else {
      final kind = _remoteKind(type);
      out.add(
        _mcpItem(
          tool: tool,
          name: e.key,
          scope: scope,
          transport: kind,
          url: _str(v['url']) ?? '',
          headers: _strMap(v['headers']),
          dropped: dropped,
          unsupported: type == 'ws' ? 'Not supported (WebSocket).' : 'Not supported ($type).',
        ),
      );
    }
  }
  return out;
}

Object? _decode(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

/// `~/.claude.json`: the user's servers, and the ones kept for each of [projects] (`projects[<path>].mcpServers`).
List<ImportItem> parseClaudeMcp(String text, {Set<String> projects = const {}}) {
  final root = _decode(text);
  if (root is! Map<String, Object?>) return const [];
  final out = _claudeServers(root['mcpServers'], null, toolClaude);
  final per = root['projects'];
  if (per is Map<String, Object?>) {
    for (final p in projects) {
      if (per[p] case final Map<String, Object?> entry) out.addAll(_claudeServers(entry['mcpServers'], p, toolClaude));
    }
  }
  return out;
}

/// A project's `.mcp.json`.
List<ImportItem> parseProjectMcpJson(String text, {required String project}) {
  final root = _decode(text);
  return root is Map<String, Object?> ? _claudeServers(root['mcpServers'], project, toolClaude) : const [];
}

/// `~/.cursor/mcp.json` or a project's `.cursor/mcp.json`.
List<ImportItem> parseCursorMcp(String text, {String? project}) {
  final root = _decode(text);
  if (root is! Map<String, Object?> || root['mcpServers'] is! Map<String, Object?>) return const [];
  final out = <ImportItem>[];
  for (final e in (root['mcpServers']! as Map<String, Object?>).entries) {
    final v = e.value;
    if (v is! Map<String, Object?>) continue;
    final dropped = [
      for (final k in const ['envFile', 'auth'])
        if (v.containsKey(k)) k,
    ];
    if (v['command'] is String) {
      out.add(
        _mcpItem(
          tool: toolCursor,
          name: e.key,
          scope: project,
          transport: McpTransport.stdio,
          command: _str(v['command']) ?? '',
          args: _strList(v['args']),
          env: _strMap(v['env']),
          dropped: dropped,
        ),
      );
    } else {
      final type = _str(v['type']);
      out.add(
        _mcpItem(
          tool: toolCursor,
          name: e.key,
          scope: project,
          transport: _remoteKind(type),
          url: _str(v['url']) ?? '',
          headers: _strMap(v['headers']),
          dropped: dropped,
          unsupported: 'Not supported ($type).',
        ),
      );
    }
  }
  return out;
}

/// Removes `//` and `/* */` comments and trailing commas outside strings (OpenCode's `opencode.jsonc`).
String stripJsonc(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == '"') {
      final start = i++;
      while (i < s.length && s[i] != '"') {
        i += s[i] == r'\' ? 2 : 1;
      }
      i = (i + 1).clamp(0, s.length);
      out.write(s.substring(start, i));
    } else if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
      while (i < s.length && s[i] != '\n') {
        i++;
      }
    } else if (c == '/' && i + 1 < s.length && s[i + 1] == '*') {
      final end = s.indexOf('*/', i + 2);
      i = end < 0 ? s.length : end + 2;
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString().replaceAllMapped(RegExp(r',(\s*[}\]])'), (m) => m.group(1)!);
}

/// OpenCode's `opencode.json[c]`: the `mcp` key.
List<ImportItem> parseOpenCodeMcp(String text, {String? project}) {
  final root = _decode(stripJsonc(text));
  if (root is! Map<String, Object?> || root['mcp'] is! Map<String, Object?>) return const [];
  final out = <ImportItem>[];
  for (final e in (root['mcp']! as Map<String, Object?>).entries) {
    final v = e.value;
    if (v is! Map<String, Object?>) continue;
    final dropped = [
      for (final k in const ['oauth', 'timeout'])
        if (v.containsKey(k)) k,
    ];
    if (v['type'] == 'local') {
      final cmd = _strList(v['command']);
      out.add(
        _mcpItem(
          tool: toolOpenCode,
          name: e.key,
          scope: project,
          transport: McpTransport.stdio,
          command: cmd.firstOrNull ?? '',
          args: cmd.skip(1).toList(),
          env: _strMap(v['environment']),
          enabled: v['enabled'] != false,
          dropped: dropped,
        ),
      );
    } else if (v['type'] == 'remote') {
      out.add(
        _mcpItem(
          tool: toolOpenCode,
          name: e.key,
          scope: project,
          transport: McpTransport.http,
          url: _str(v['url']) ?? '',
          headers: _strMap(v['headers']),
          enabled: v['enabled'] != false,
          dropped: dropped,
        ),
      );
    }
  }
  return out;
}

/// Codex's `config.toml`: the `[mcp_servers.*]` tables.
List<ImportItem> parseCodexMcp(String text) {
  final parsed = parseCodexToml(text);
  final out = <ImportItem>[];
  for (final name in parsed.bad) {
    out.add(
      ImportItem(
        kind: ImportKind.mcp,
        source: toolCodex,
        title: mcpName(name),
        unavailable: "Couldn't read this server's settings.",
      ),
    );
  }
  for (final e in parsed.servers.entries) {
    final v = e.value;
    final dropped = [
      for (final k in const ['cwd', 'startup_timeout_sec', 'tool_timeout_sec', 'enabled_tools', 'disabled_tools'])
        if (v.containsKey(k)) k,
    ];
    if (v['command'] is String) {
      out.add(
        _mcpItem(
          tool: toolCodex,
          name: e.key,
          scope: null,
          transport: McpTransport.stdio,
          command: _str(v['command']) ?? '',
          args: _strList(v['args']),
          env: _strMap(v['env']),
          enabled: v['enabled'] != false,
          dropped: dropped,
        ),
      );
    } else if (v['url'] is String) {
      final bearer = v['bearer_token_env_var'];
      out.add(
        _mcpItem(
          tool: toolCodex,
          name: e.key,
          scope: null,
          transport: McpTransport.http,
          url: v['url']! as String,
          headers: {
            ..._strMap(v['http_headers']),
            for (final h in _strMap(v['env_http_headers']).entries) h.key: '\${${h.value}}',
            if (bearer is String) 'Authorization': 'Bearer \${$bearer}',
          },
          enabled: v['enabled'] != false,
          dropped: dropped,
        ),
      );
    }
  }
  return out;
}

String _contentKey(McpServer s) =>
    jsonEncode({'t': s.transport.name, 'c': s.command, 'a': s.args, 'e': s.env, 'u': s.url, 'h': s.headers});

/// One row per server: the same server found in several tools becomes one row ("Claude Code, Cursor"); different
/// servers sharing a name get the tool's name added. Order is kept.
List<ImportItem> mergeMcpItems(List<ImportItem> items) {
  final out = <ImportItem>[];
  for (final it in items) {
    final s = it.mcp;
    if (s == null) {
      out.add(it);
      continue;
    }
    final same = out.indexWhere((o) => o.mcp != null && o.scope == it.scope && _contentKey(o.mcp!) == _contentKey(s));
    if (same >= 0 && out[same].mcp!.name == s.name) {
      if (!out[same].source.split(', ').contains(it.source)) {
        out[same] = out[same].copyWith(source: '${out[same].source}, ${it.source}');
      }
      continue;
    }
    var named = it;
    if (out.any((o) => o.kind == ImportKind.mcp && o.scope == it.scope && o.title == it.title)) {
      var n = mcpName('${s.name}-${it.source.toLowerCase().replaceAll(' ', '')}');
      var k = 2;
      while (out.any((o) => o.kind == ImportKind.mcp && o.scope == it.scope && o.title == n)) {
        n = mcpName('${s.name}-${it.source.toLowerCase().replaceAll(' ', '')}-${k++}');
      }
      named = ImportItem(
        kind: it.kind,
        source: it.source,
        title: n,
        scope: it.scope,
        detail: it.detail,
        notes: [...it.notes, 'Another server called "${s.name}" is also listed; this one is named $n.'],
        unavailable: it.unavailable,
        checked: it.checked,
        mcp: McpServer(
          name: n,
          transport: s.transport,
          command: s.command,
          args: s.args,
          env: s.env,
          url: s.url,
          headers: s.headers,
          enabled: s.enabled,
          description: s.description,
        ),
      );
    }
    out.add(named);
  }
  return out;
}

// ------------------------------------------------------------------------------------------------- Codex TOML

/// The `[mcp_servers.<name>]` tables of a Codex `config.toml` (a subset reader: strings, booleans, numbers, arrays,
/// inline tables, sub-tables such as `.env`; everything outside `mcp_servers` is skipped). [bad] names the servers
/// whose tables could not be read.
({Map<String, Map<String, Object?>> servers, List<String> bad}) parseCodexToml(String text) {
  final servers = <String, Map<String, Object?>>{};
  final bad = <String>{};
  List<String>? table; // path under mcp_servers, or null outside it
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  var i = 0;
  while (i < lines.length) {
    var line = _tomlStrip(lines[i++]).trim();
    if (line.isEmpty) continue;
    if (line.startsWith('[')) {
      if (line.startsWith('[[')) {
        table = null;
        continue;
      }
      final close = line.lastIndexOf(']');
      final path = close < 0 ? null : _tomlKey(line.substring(1, close));
      if (path == null || path.isEmpty) {
        table = null;
      } else if (path.length == 1 && path.first == 'mcp_servers') {
        table = const []; // `name = { … }` lines, one server each
      } else if (path.first == 'mcp_servers' && path.length >= 2) {
        table = path.sublist(1);
        servers.putIfAbsent(table.first, () => {});
      } else {
        table = null;
      }
      continue;
    }
    if (table == null) {
      // A multi-line value outside our tables: skip its continuation lines.
      while (_tomlOpen(line) && i < lines.length) {
        line = '$line ${_tomlStrip(lines[i++]).trim()}';
      }
      continue;
    }
    while (_tomlOpen(line) && i < lines.length) {
      line = '$line ${_tomlStrip(lines[i++]).trim()}';
    }
    final eq = _tomlEquals(line);
    if (table.isEmpty) {
      // A plain [mcp_servers] table: each key is a server given as an inline table.
      final name = eq < 0 ? null : _tomlKey(line.substring(0, eq));
      final value = eq < 0 ? _bad : _TomlValue(line.substring(eq + 1).trim()).read();
      if (name == null || name.length != 1) {
        continue;
      } else if (value is Map<String, Object?>) {
        servers[name.first] = value;
      } else {
        bad.add(name.first);
      }
      continue;
    }
    if (eq < 0) {
      bad.add(table.first);
      continue;
    }
    final key = _tomlKey(line.substring(0, eq));
    final value = _TomlValue(line.substring(eq + 1).trim()).read();
    if (key == null || key.isEmpty || value == _bad) {
      bad.add(table.first);
      continue;
    }
    // table.sublist(1) are sub-table names (`env`); key may itself be dotted.
    var into = servers[table.first]!;
    for (final part in [...table.sublist(1), ...key.sublist(0, key.length - 1)]) {
      final next = into[part];
      into = next is Map<String, Object?> ? next : (into[part] = <String, Object?>{});
    }
    into[key.last] = value;
  }
  for (final b in bad) {
    servers.remove(b);
  }
  return (servers: servers, bad: bad.toList());
}

const Object _bad = _BadValue();

class _BadValue {
  const _BadValue();
}

/// The text without a trailing `#` comment (outside strings).
String _tomlStrip(String line) {
  String? q;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (q != null) {
      if (c == r'\' && q == '"') {
        i++;
      } else if (c == q) {
        q = null;
      }
    } else if (c == '"' || c == "'") {
      q = c;
    } else if (c == '#') {
      return line.substring(0, i);
    }
  }
  return line;
}

/// Whether a value on this line still has an open `[` or `{`.
bool _tomlOpen(String line) {
  final eq = _tomlEquals(line);
  if (eq < 0) return false;
  var depth = 0;
  String? q;
  final v = line.substring(eq + 1);
  for (var i = 0; i < v.length; i++) {
    final c = v[i];
    if (q != null) {
      if (c == r'\' && q == '"') {
        i++;
      } else if (c == q) {
        q = null;
      }
    } else if (c == '"' || c == "'") {
      q = c;
    } else if (c == '[' || c == '{') {
      depth++;
    } else if (c == ']' || c == '}') {
      depth--;
    }
  }
  return depth > 0;
}

/// The first `=` outside quotes.
int _tomlEquals(String line) {
  String? q;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (q != null) {
      if (c == q) q = null;
    } else if (c == '"' || c == "'") {
      q = c;
    } else if (c == '=') {
      return i;
    }
  }
  return -1;
}

/// `a.b."c.d"` as its parts; null when malformed.
List<String>? _tomlKey(String raw) {
  final parts = <String>[];
  var i = 0;
  final s = raw.trim();
  while (i < s.length) {
    while (i < s.length && s[i] == ' ') {
      i++;
    }
    if (i >= s.length) return null;
    if (s[i] == '"' || s[i] == "'") {
      final r = _TomlValue(s.substring(i));
      final v = r.readString();
      if (v == null) return null;
      parts.add(v);
      i += r.pos;
    } else {
      final m = RegExp(r'[A-Za-z0-9_-]+').matchAsPrefix(s, i);
      if (m == null) return null;
      parts.add(m.group(0)!);
      i = m.end;
    }
    while (i < s.length && s[i] == ' ') {
      i++;
    }
    if (i < s.length) {
      if (s[i] != '.') return null;
      i++;
    }
  }
  return parts;
}

class _TomlValue {
  _TomlValue(this.s);
  final String s;
  int pos = 0;

  void _ws() {
    while (pos < s.length && (s[pos] == ' ' || s[pos] == '\t' || s[pos] == '\n')) {
      pos++;
    }
  }

  /// A value, or [_bad]; the whole text must be consumed.
  Object? read() {
    final v = _value();
    _ws();
    return pos == s.length ? v : _bad;
  }

  Object? _value() {
    _ws();
    if (pos >= s.length) return _bad;
    final c = s[pos];
    if (c == '"' || c == "'") return readString() ?? _bad;
    if (c == '[') {
      pos++;
      final list = <Object?>[];
      while (true) {
        _ws();
        if (pos >= s.length) return _bad;
        if (s[pos] == ']') {
          pos++;
          return list;
        }
        final v = _value();
        if (v == _bad) return _bad;
        list.add(v);
        _ws();
        if (pos < s.length && s[pos] == ',') pos++;
      }
    }
    if (c == '{') {
      pos++;
      final map = <String, Object?>{};
      while (true) {
        _ws();
        if (pos >= s.length) return _bad;
        if (s[pos] == '}') {
          pos++;
          return map;
        }
        final eq = _tomlEquals(s.substring(pos));
        if (eq < 0) return _bad;
        final key = _tomlKey(s.substring(pos, pos + eq));
        if (key == null || key.length != 1) return _bad;
        pos += eq + 1;
        final v = _value();
        if (v == _bad) return _bad;
        map[key.first] = v;
        _ws();
        if (pos < s.length && s[pos] == ',') pos++;
      }
    }
    final m = RegExp(r'[^\s,\]}]+').matchAsPrefix(s, pos);
    if (m == null) return _bad;
    pos = m.end;
    final t = m.group(0)!;
    if (t == 'true') return true;
    if (t == 'false') return false;
    return num.tryParse(t.replaceAll('_', '')) ?? _bad;
  }

  /// A basic (`"…"`) or literal (`'…'`) string at [pos]; null when unterminated or multi-line.
  String? readString() {
    final q = s[pos];
    if (s.startsWith(q * 3, pos)) return null;
    final b = StringBuffer();
    var i = pos + 1;
    while (i < s.length) {
      final c = s[i];
      if (c == q) {
        pos = i + 1;
        return b.toString();
      }
      if (c == r'\' && q == '"') {
        if (i + 1 >= s.length) return null;
        final n = s[i + 1];
        i += 2;
        switch (n) {
          case 'n':
            b.write('\n');
          case 't':
            b.write('\t');
          case 'r':
            b.write('\r');
          case '"' || r'\':
            b.write(n);
          case 'u':
            final cp = i + 4 <= s.length ? int.tryParse(s.substring(i, i + 4), radix: 16) : null;
            if (cp == null) return null;
            b.writeCharCode(cp);
            i += 4;
          default:
            return null;
        }
        continue;
      }
      b.write(c);
      i++;
    }
    return null;
  }
}

// --------------------------------------------------------------------------------------- commands and agents

/// Splits `---` front matter into top-level `key: value` pairs (a value continued on indented or `-` lines is joined
/// with spaces) and the body. Lenient: never throws; no front matter gives an empty map.
({Map<String, String> meta, String body}) _lenientFront(String source) {
  final text = source.replaceAll('\r\n', '\n').replaceFirst('﻿', '');
  final m = RegExp(r'^---[ \t]*\n([\s\S]*?)\n---[ \t]*(?:\n|$)').firstMatch(text);
  if (m == null) return (meta: const {}, body: text);
  final meta = <String, String>{};
  String? key;
  for (final line in m.group(1)!.split('\n')) {
    final kv = RegExp(r'^([A-Za-z0-9_-]+)\s*:\s*(.*)$').firstMatch(line);
    if (kv != null && !line.startsWith(' ')) {
      key = kv.group(1)!;
      meta[key] = kv.group(2)!.trim();
    } else if (key != null && line.trim().isNotEmpty && !line.trimLeft().startsWith('#')) {
      final cont = line.trim().replaceFirst(RegExp(r'^-\s+'), '');
      meta[key] = [meta[key]!, cont].where((s) => s.isNotEmpty).join(' ');
    }
  }
  String clean(String v) {
    var t = v.trim();
    if (t == '|' || t == '>' || t == '|-' || t == '>-') return '';
    if (t.length >= 2 && (t.startsWith('"') && t.endsWith('"') || t.startsWith("'") && t.endsWith("'"))) {
      t = t.substring(1, t.length - 1);
    }
    return t.trim();
  }

  return (meta: {for (final e in meta.entries) e.key: clean(e.value)}, body: text.substring(m.end));
}

/// A command name from a path under the commands folder: `review/pr.md` becomes `review-pr`. Null when nothing valid
/// is left.
String? commandNameFor(String relativePath) {
  final stem = relativePath
      .replaceAll('\\', '/')
      .replaceFirst(RegExp(r'\.md$'), '')
      .split('/')
      .where((s) => s.isNotEmpty)
      .join('-')
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
      .replaceFirst(RegExp(r'^[^a-z0-9]+'), '');
  final name = stem.length > 48 ? stem.substring(0, 48) : stem;
  return CustomCommand.validName.hasMatch(name) ? name : null;
}

/// The result of mapping one command file: [item] is always there; its [ImportItem.unavailable] says why not.
ImportItem mapClaudeCommand(String relativePath, String text, {String? project}) =>
    _mapCommand(toolClaude, relativePath, text, project, claude: true);

ImportItem mapCursorCommand(String relativePath, String text, {String? project}) =>
    _mapCommand(toolCursor, relativePath, text, project, claude: false);

ImportItem _mapCommand(String tool, String relPath, String text, String? project, {required bool claude}) {
  ImportItem fail(String name, String why) => ImportItem(
    kind: ImportKind.command,
    source: tool,
    title: name,
    scope: project,
    unavailable: "Can't be brought over: $why",
  );
  final name = commandNameFor(relPath);
  if (name == null) return fail(relPath, 'its name has no letters or digits to use.');
  final (:meta, :body) = claude ? _lenientFront(text) : (meta: <String, String>{}, body: text);
  if (claude) {
    if (body.contains('!`') || body.contains('```!')) return fail(name, 'it runs shell commands inline (!`…`).');
    if (body.contains(r'$ARGUMENTS[')) return fail(name, r'it uses $ARGUMENTS[N].');
    if (meta.containsKey('arguments') && meta['arguments']!.isNotEmpty) {
      return fail(name, 'it uses named arguments.');
    }
    if (RegExp(r'\\\$(\d|ARGUMENTS)').hasMatch(body)) return fail(name, r'it escapes a $ placeholder.');
  }
  var out = body;
  final notes = <String>[];
  if (claude) {
    var tooHigh = false;
    // Claude counts arguments from 0, EveryAI from 1.
    out = out.replaceAllMapped(RegExp(r'\$(\d+)'), (m) {
      final n = int.parse(m.group(1)!);
      if (n > 8) tooHigh = true;
      return '\$${n + 1}';
    });
    if (tooHigh) return fail(name, r'it uses more than 9 arguments ($9 and up).');
    if (RegExp(r'(^|\s)@[\w./~-]+').hasMatch(out)) {
      notes.add('@file references are sent as plain text.');
    }
    final lost = [
      for (final k in const ['allowed-tools', 'disable-model-invocation', 'hooks', 'context', 'agent'])
        if (meta.containsKey(k)) k,
    ];
    if (lost.isNotEmpty) notes.add('Left out (no equivalent): ${lost.join(', ')}.');
  }
  final model = meta['model'];
  final keepModel = model != null && RegExp(r'^[a-z0-9._~-]+/[A-Za-z0-9._:~-]+$').hasMatch(model);
  if (model != null && model.isNotEmpty && !keepModel) notes.add('Model "$model" is not carried over.');
  final command = CustomCommand.parse(
    name,
    CustomCommand(
      name: name,
      body: out.trim(),
      description: meta['description'] ?? '',
      args: meta['argument-hint'],
      model: keepModel ? model : null,
    ).toSource(),
  );
  final hidden = command.findings;
  if (hidden.isNotEmpty) notes.add('Has hidden or suspicious text; look at it before importing.');
  return ImportItem(
    kind: ImportKind.command,
    source: tool,
    title: '/$name',
    scope: project,
    detail: command.description,
    notes: notes,
    checked: project == null && hidden.isEmpty,
    command: command,
  );
}

/// A Claude subagent file written again in EveryAI's agent format. Claude's `tools`, `model` aliases, `skills`,
/// `mcpServers` and hooks have no equivalent and are left out (named in the row).
ImportItem mapClaudeAgent(String fileName, String text, {String? project}) {
  final (:meta, :body) = _lenientFront(text);
  final stem = fileName.split(RegExp(r'[/\\]')).last.replaceFirst(RegExp(r'\.md$'), '');
  final name = (meta['name'] ?? stem).toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]+'), '-');
  ImportItem fail(String why) => ImportItem(
    kind: ImportKind.agent,
    source: toolClaude,
    title: name.isEmpty ? stem : name,
    scope: project,
    unavailable: "Can't be brought over: $why",
  );
  if (!agentNamePattern.hasMatch(name)) return fail('its name has no letters or digits to use.');
  final description = (meta['description'] ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (description.isEmpty) return fail('it has no description.');
  final notes = <String>[];
  final head = <String>['name: $name', 'description: ${jsonEncode(description)}'];
  final model = meta['model'];
  if (model != null && RegExp(r'^[a-z0-9._~-]+/[A-Za-z0-9._:~-]+$').hasMatch(model)) {
    head.add('model: $model');
  }
  final effort = meta['effort']?.toLowerCase();
  if (effort != null && agentEfforts.contains(effort)) head.add('effort: $effort');
  final raw = meta['permissionMode'];
  if (raw != null && raw.isNotEmpty) {
    final mode = parseAgentMode(raw);
    if (mode == null || mode.runsFreely || mode == AgentMode.bypass) {
      notes.add('Permission mode "$raw" is not carried over; it asks like any session.');
    } else {
      head.add(
        'permissions: ${const {AgentMode.ask: 'ask', AgentMode.autoEdit: 'auto-edit', AgentMode.plan: 'plan'}[mode]}',
      );
    }
  }
  final lost = [
    for (final k in const ['tools', 'disallowedTools', 'model', 'skills', 'mcpServers', 'hooks', 'color', 'memory'])
      if (meta.containsKey(k) && !(k == 'model' && head.any((h) => h.startsWith('model:')))) k,
  ];
  if (lost.isNotEmpty) notes.add('Left out (no equivalent): ${lost.join(', ')}.');
  final file = '---\n${head.join('\n')}\n---\n${body.trim()}\n';
  final hidden = scanInstructions(text, file: fileName).isNotEmpty;
  if (hidden) notes.add('Has hidden or suspicious text; look at it before importing.');
  return ImportItem(
    kind: ImportKind.agent,
    source: toolClaude,
    title: name,
    scope: project,
    detail: description.length > 100 ? '${description.substring(0, 97)}...' : description,
    notes: notes,
    checked: project == null && !hidden,
    agentName: name,
    agentText: file,
  );
}

// ---------------------------------------------------------------------------------------------- rules files

/// Rules files among [paths] (full paths), listed as found. Nothing is copied: the row says whether EveryAI reads
/// the file as it is.
List<ImportItem> findRuleFiles(Iterable<String> paths, {String? project}) {
  // EveryAI reads one of these per folder, the first in [contextFileNames] order, and only inside a project; the
  // user-level file (no project) is not read at all.
  final first = <String, String>{};
  for (final name in contextFileNames) {
    for (final p in paths) {
      final norm = p.replaceAll('\\', '/');
      if (norm.split('/').last == name) first.putIfAbsent(norm.substring(0, norm.lastIndexOf('/') + 1), () => p);
    }
  }
  final out = <ImportItem>[];
  for (final p in paths) {
    final norm = p.replaceAll('\\', '/');
    final base = norm.split('/').last;
    final tool = switch (base) {
      'CLAUDE.md' => toolClaude,
      'GEMINI.md' => 'Gemini CLI',
      'AGENTS.md' || 'AGENTS.override.md' => 'AGENTS.md',
      '.cursorrules' => toolCursor,
      _ when base.endsWith('.mdc') || norm.contains('.cursor/rules/') => toolCursor,
      _ => null,
    };
    if (tool == null) continue;
    final named = contextFileNames.contains(base);
    final used = named && project != null && first[norm.substring(0, norm.lastIndexOf('/') + 1)] == p;
    out.add(
      ImportItem(
        kind: ImportKind.rule,
        source: tool,
        title: norm.split('/').reversed.take(norm.contains('.cursor/rules/') ? 3 : 1).toList().reversed.join('/'),
        scope: project,
        detail: used
            ? 'EveryAI reads it where it is.'
            : named && project == null
            ? 'EveryAI does not read this one; copy what you need into a project\'s AGENTS.md.'
            : named
            ? 'Skipped: another rules file in this folder is read instead.'
            : 'EveryAI does not read it.',
        path: p,
        used: used,
        checked: false,
      ),
    );
  }
  return out;
}
