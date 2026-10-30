import 'dart:io';

export 'research_sites.dart';

/// Finds secrets in what an agent is about to send out (a fetched URL, a
/// search query), so a prompt-injected page can't have them carried off.
/// Looks for the values of secret-named environment variables, values from
/// the project's `.env*` files, the gateway key, and well-known key shapes.
final class Scrubber {
  Scrubber({Map<String, String> env = const {}, Iterable<String> values = const []})
    : _values = {
        for (final MapEntry(:key, :value) in env.entries)
          if (_secretName.hasMatch(key) && value.trim().length >= 8) value.trim(),
        for (final v in values)
          if (v.trim().length >= 8) v.trim(),
      };

  /// The user's environment and the `.env*` files in [projectDir], plus [extra]
  /// (the gateway key).
  factory Scrubber.forProject(String projectDir, {Iterable<String> extra = const []}) =>
      Scrubber(env: Platform.environment, values: [...extra, ...dotEnvValues(projectDir)]);

  final Set<String> _values;

  static final _secretName = RegExp(
    r'(KEY|TOKEN|SECRET|PASSWORD|PASSWD|PASS|AUTH|CREDENTIAL|PRIVATE|COOKIE|SESSION|DSN|CONN)',
    caseSensitive: false,
  );

  static final _shapes = <(String, RegExp)>[
    ('an API key', RegExp(r'\b(sk|rk|pk)-[A-Za-z0-9_\-]{20,}')),
    ('a GitHub token', RegExp(r'\b(ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}')),
    ('a Hugging Face token', RegExp(r'\bhf_[A-Za-z0-9]{20,}')),
    ('an AWS key', RegExp(r'\b(AKIA|ASIA)[0-9A-Z]{16}\b')),
    ('a Slack token', RegExp(r'\bxox[abposr]-[A-Za-z0-9\-]{10,}')),
    ('a Google API key', RegExp(r'\bAIza[0-9A-Za-z_\-]{30,}')),
    ('a private key', RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY')),
    ('a JWT', RegExp(r'\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}')),
    // Longer than any commit hash or content id a URL needs.
    ('a long hex blob', RegExp(r'[0-9a-fA-F]{64,}')),
    ('a long base64 blob', RegExp(r'[A-Za-z0-9+/_\-]{120,}={0,2}')),
  ];

  /// What [text] would leak, or null when it looks clean.
  String? leak(String text) {
    final decoded = _decoded(text);
    for (final v in _values) {
      if (text.contains(v) || decoded.contains(v)) return 'a secret from your environment or .env files';
    }
    for (final (what, re) in _shapes) {
      if (re.hasMatch(text) || re.hasMatch(decoded)) return what;
    }
    return null;
  }

  static String _decoded(String text) {
    try {
      return Uri.decodeFull(text);
    } on Object {
      return text;
    }
  }

  /// The values set in `.env`, `.env.local` and the like in [dir].
  static List<String> dotEnvValues(String dir) {
    final out = <String>[];
    try {
      for (final f in Directory(dir).listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (!name.startsWith('.env') || name.endsWith('.example') || name.endsWith('.sample')) continue;
        for (final line in f.readAsLinesSync()) {
          final eq = line.indexOf('=');
          if (line.trimLeft().startsWith('#') || eq < 1) continue;
          var v = line.substring(eq + 1).trim();
          if (v.length >= 2 && (v[0] == '"' || v[0] == "'") && v.endsWith(v[0])) v = v.substring(1, v.length - 1);
          out.add(v);
        }
      }
    } on Object {
      // An unreadable folder has nothing to add.
    }
    return out;
  }
}
