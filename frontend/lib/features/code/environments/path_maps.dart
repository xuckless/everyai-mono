// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

/// A host folder shared into an environment at [env].
typedef Mount = ({String host, String env, bool writable});

/// Host ↔ environment paths through shared folders (bind mounts, VM shares):
/// the longest matching folder wins, whole path segments only (`/Users/a`
/// doesn't match `/Users/ab`). Null when no shared folder holds the path, or
/// when the path has a `..` segment (it could climb out of the share).
///
/// Windows host paths match in any of their forms: `C:\x`, `c:/x`, and
/// Docker Desktop's `/run/desktop/mnt/host/c/x` (its WSL2 backend), without
/// regard to case; they come back as `C:\x`.
final class MountMap {
  const MountMap(this.mounts);

  final List<Mount> mounts;

  String? toEnv(String hostPath) {
    final path = _hostForm(hostPath);
    final m = path == null ? null : _match(path, (m) => _hostForm(m.host));
    if (m == null) return null;
    return _join(_trim(m.env), path!.substring(_trim(_hostForm(m.host)!).length));
  }

  String? toHost(String envPath) {
    if (!_posix(envPath)) return null;
    final m = _match(envPath, (m) => _hostForm(m.host) == null ? null : m.env);
    if (m == null) return null;
    final host = _join(_trim(_hostForm(m.host)!), envPath.substring(_trim(m.env).length));
    if (!_windows.hasMatch(host)) return host;
    return '${host[0].toUpperCase()}:\\${host.length > 3 ? host.substring(3).replaceAll('/', '\\') : ''}';
  }

  /// Whether the folder that holds [hostPath] is writable inside, or null
  /// when none does.
  bool? writableAt(String hostPath) {
    final path = _hostForm(hostPath);
    return path == null ? null : _match(path, (m) => _hostForm(m.host))?.writable;
  }

  Mount? _match(String path, String? Function(Mount) from) {
    Mount? best;
    var bestLength = -1;
    for (final m in mounts) {
      final raw = from(m);
      if (raw == null) continue;
      final prefix = _trim(raw);
      if (!_under(path, prefix) || prefix.length <= bestLength) continue;
      best = m;
      bestLength = prefix.length;
    }
    return best;
  }
}

String _join(String base, String rest) => rest.isEmpty ? (base.isEmpty ? '/' : base) : '$base$rest';

final _windows = RegExp(r'^[a-z]:(/|$)');
final _desktopHost = RegExp(r'^/run/desktop/mnt/host/([A-Za-z])(?:/(.*))?$', dotAll: true);

/// An absolute path with no `..` segment, `/`-separated.
bool _posix(String p) => p.startsWith('/') && !p.split('/').contains('..');

/// [p] in the one form paths are matched in: POSIX paths as they are,
/// Windows ones as `c:/x` (lowercase drive, `/`). Null for a relative path or
/// one with a `..` segment.
String? _hostForm(String p) {
  final w = _drive.firstMatch(p) ?? _desktopHost.firstMatch(p);
  if (w == null) return _posix(p) ? p : null;
  final rest = (w.group(2) ?? '').replaceAll('\\', '/');
  if (rest.split('/').contains('..')) return null;
  return '${w.group(1)!.toLowerCase()}:/$rest';
}

// '/' becomes '' so that every prefix test is "equal, or followed by /";
// `c:/` becomes `c:` the same way.
String _trim(String p) => p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : (p == '/' ? '' : p);

bool _under(String path, String prefix) {
  if (_windows.hasMatch(path)) {
    // Windows paths ignore case; ASCII lowercasing keeps the lengths.
    final l = path.toLowerCase(), q = prefix.toLowerCase();
    return q.isNotEmpty && (l == q || l.startsWith('$q/'));
  }
  return path.startsWith('/') && (path == prefix || path.startsWith('$prefix/') || (prefix.isEmpty && path == '/'));
}

final _drive = RegExp(r'^([A-Za-z]):(?:[\\/](.*))?$', dotAll: true);
final _unc = RegExp(r'^//(wsl\$|wsl\.localhost)/([^/]+)(/.*)?$', caseSensitive: false, dotAll: true);

/// A Windows path as WSL distro [distro] sees it: `C:\x` → `<root>c/x`
/// (`root` is the automount root, `/mnt/` unless `/etc/wsl.conf` says
/// otherwise), `\\wsl$\<distro>\x` and `\\wsl.localhost\<distro>\x` → `/x`.
/// Null for another distro's files or a network share.
String? wslToEnvPath(String hostPath, {required String distro, String root = '/mnt/'}) {
  final r = root.endsWith('/') ? root : '$root/';
  final d = _drive.firstMatch(hostPath);
  if (d != null) {
    final rest = (d.group(2) ?? '').replaceAll('\\', '/');
    final drive = '$r${d.group(1)!.toLowerCase()}';
    return d.group(2) == null ? drive : '$drive/$rest';
  }
  final u = _unc.firstMatch(hostPath.replaceAll('\\', '/'));
  if (u != null && u.group(2)!.toLowerCase() == distro.toLowerCase()) return u.group(3) ?? '/';
  return null;
}

/// A path inside WSL distro [distro] as Windows sees it: `<root>c/x` →
/// `C:\x`, anything else → `\\wsl.localhost\<distro>\x`. Null for a
/// relative path.
String? wslToHostPath(String envPath, {required String distro, String root = '/mnt/'}) {
  if (!envPath.startsWith('/')) return null;
  final r = root.endsWith('/') ? root : '$root/';
  if (envPath.startsWith(r)) {
    final rest = envPath.substring(r.length);
    final m = RegExp(r'^([A-Za-z])(?:/(.*))?$', dotAll: true).firstMatch(rest);
    if (m != null) return '${m.group(1)!.toUpperCase()}:\\${(m.group(2) ?? '').replaceAll('/', '\\')}';
  }
  return '\\\\wsl.localhost\\$distro${envPath.replaceAll('/', '\\')}';
}
