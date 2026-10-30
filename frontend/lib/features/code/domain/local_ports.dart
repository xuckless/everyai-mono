import 'package:flutter/foundation.dart';

/// A TCP port a process listens on.
@immutable
final class ListeningPort {
  const ListeningPort({required this.pid, required this.port, this.host = '*'});

  final int pid;
  final int port;

  /// The bound address: `*` for every interface, else `127.0.0.1`, `::1`…
  final String host;

  /// Whether the port can be reached through `localhost`.
  bool get local => host == '*' || host == '0.0.0.0' || host == '::' || host.startsWith('127.') || host == '::1';

  @override
  bool operator ==(Object other) =>
      other is ListeningPort && other.pid == pid && other.port == port && other.host == host;

  @override
  int get hashCode => Object.hash(pid, port, host);

  @override
  String toString() => 'ListeningPort($pid, $host:$port)';
}

/// Splits `host:port` (`*:3000`, `127.0.0.1:5173`, `[::1]:8080`).
(String, int)? _hostPort(String address) {
  final colon = address.lastIndexOf(':');
  if (colon <= 0) return null;
  final port = int.tryParse(address.substring(colon + 1));
  if (port == null || port <= 0 || port > 65535) return null;
  var host = address.substring(0, colon);
  if (host.startsWith('[') && host.endsWith(']')) host = host.substring(1, host.length - 1);
  return (host, port);
}

/// Parses `lsof -nP -iTCP -sTCP:LISTEN -Fpn` (macOS, Linux): a `p<pid>` line
/// starts each process, `n<host>:<port>` lines name its sockets. Duplicates
/// (one per IPv4/IPv6 socket) are kept apart by host.
List<ListeningPort> parseLsofListen(String output) {
  final out = <ListeningPort>{};
  int? pid;
  for (final line in output.split('\n')) {
    if (line.isEmpty) continue;
    switch (line[0]) {
      case 'p':
        pid = int.tryParse(line.substring(1));
      case 'n' when pid != null:
        // A connected socket reads `a:1->b:2`; a listener has no arrow.
        final name = line.substring(1);
        if (name.contains('->')) continue;
        if (_hostPort(name) case (final host, final port)) out.add(ListeningPort(pid: pid, port: port, host: host));
    }
  }
  return out.toList();
}

/// Parses `ss -Hltnp` (Linux):
/// `LISTEN 0 511 127.0.0.1:5173 0.0.0.0:* users:(("node",pid=1234,fd=20))`.
List<ListeningPort> parseSsListen(String output) {
  final out = <ListeningPort>{};
  final pids = RegExp(r'pid=(\d+)');
  for (final line in output.split('\n')) {
    final cols = line.trim().split(RegExp(r'\s+'));
    if (cols.length < 5) continue;
    // The local address is the 4th column; the state may be missing with -l.
    final local = cols[0] == 'LISTEN' ? cols[3] : cols[2];
    final hp = _hostPort(local.replaceFirst(RegExp(r'%\S+(?=:)'), ''));
    if (hp == null) continue;
    for (final m in pids.allMatches(line)) {
      out.add(ListeningPort(pid: int.parse(m.group(1)!), port: hp.$2, host: hp.$1));
    }
  }
  return out.toList();
}

final _ansi = RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])');

/// Removes terminal escape sequences (colours, cursor moves, titles).
String stripAnsi(String text) => text.replaceAll(_ansi, '');

final _localUrl = RegExp(
  r'''https?://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(?::(\d{1,5}))?(/[^\s'"<>`)\]]*)?''',
  caseSensitive: false,
);

/// The local web addresses printed in [text] (a dev server's "Local:
/// http://localhost:5173/"), newest last, without duplicates. Every loopback
/// or wildcard host becomes `localhost`; trailing punctuation is dropped.
List<String> detectLocalUrls(String text) {
  final seen = <String>[];
  for (final m in _localUrl.allMatches(stripAnsi(text))) {
    final scheme = m.group(0)!.toLowerCase().startsWith('https') ? 'https' : 'http';
    final port = m.group(2);
    if (port != null && (int.parse(port) == 0 || int.parse(port) > 65535)) continue;
    var path = m.group(3) ?? '/';
    path = path.replaceFirst(RegExp(r'[.,;:!?]+$'), '');
    if (path.isEmpty) path = '/';
    final url = '$scheme://localhost${port == null ? '' : ':$port'}$path';
    seen
      ..remove(url)
      ..add(url);
  }
  return seen;
}

/// `http://localhost:<port>/`.
String urlForPort(int port) => 'http://localhost:$port/';

/// What the user typed in the Preview address field, as a URL: a bare port
/// (`3000`), `localhost:3000/x`, `:8080` or a full URL. Null when empty.
String? normalizePreviewUrl(String typed) {
  final t = typed.trim();
  if (t.isEmpty) return null;
  if (RegExp(r'^:?\d{1,5}$').hasMatch(t)) return urlForPort(int.parse(t.replaceFirst(':', '')));
  if (RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false).hasMatch(t)) return t;
  if (t.startsWith(':')) return 'http://localhost$t';
  return 'http://$t';
}

/// The addresses Preview offers: URLs printed in the terminals (newest
/// first), then one per local listening port not already among them.
List<String> previewCandidates({Iterable<String> printed = const [], Iterable<ListeningPort> ports = const []}) {
  final out = <String>[];
  for (final u in printed.toList().reversed) {
    if (!out.contains(u)) out.add(u);
  }
  bool hasPort(int p) => out.any((u) => Uri.tryParse(u)?.port == p);
  final sorted = ports.where((p) => p.local).map((p) => p.port).toSet().toList()..sort();
  for (final p in sorted) {
    if (!hasPort(p)) out.add(urlForPort(p));
  }
  return out;
}
