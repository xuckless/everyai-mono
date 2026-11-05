// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

/// A host folder shared into an environment at [env].
typedef Mount = ({String host, String env, bool writable});

/// Host ↔ environment paths through shared folders (bind mounts, VM shares):
/// the longest matching folder wins, whole path segments only (`/Users/a`
/// doesn't match `/Users/ab`). Null when no shared folder holds the path.
final class MountMap {
  const MountMap(this.mounts);

  final List<Mount> mounts;

  String? toEnv(String hostPath) => _best(hostPath, (m) => m.host, (m) => m.env);

  String? toHost(String envPath) => _best(envPath, (m) => m.env, (m) => m.host);

  /// Whether the folder that holds [hostPath] is writable inside, or null
  /// when none does.
  bool? writableAt(String hostPath) {
    final m = _match(hostPath, (m) => m.host);
    return m?.writable;
  }

  Mount? _match(String path, String Function(Mount) from) {
    Mount? best;
    var bestLength = -1;
    for (final m in mounts) {
      final prefix = _trim(from(m));
      if (!_under(path, prefix) || prefix.length <= bestLength) continue;
      best = m;
      bestLength = prefix.length;
    }
    return best;
  }

  String? _best(String path, String Function(Mount) from, String Function(Mount) to) {
    final m = _match(path, from);
    if (m == null) return null;
    final rest = path.substring(_trim(from(m)).length);
    final base = _trim(to(m));
    if (rest.isEmpty) return base.isEmpty ? '/' : base;
    return base.isEmpty ? rest : '$base$rest';
  }
}

// '/' becomes '' so that every prefix test is "equal, or followed by /".
String _trim(String p) => p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : (p == '/' ? '' : p);

bool _under(String path, String prefix) =>
    path.startsWith('/') && (path == prefix || path.startsWith('$prefix/') || (prefix.isEmpty && path == '/'));

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
