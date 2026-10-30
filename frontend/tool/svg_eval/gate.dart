import 'dart:io';

/// Result of the render gate for one output.
class GateResult {
  const GateResult({required this.parses, required this.problems, this.rendered, this.bytes = 0, this.paths = 0});

  /// Structurally valid (root `svg`, balanced tags, nothing disallowed).
  final bool parses;

  /// Whether rsvg-convert rasterized it; null when the tool is unavailable.
  final bool? rendered;
  final List<String> problems;
  final int bytes;
  final int paths;

  bool get pass => parses && rendered != false;

  Map<String, Object?> toJson() => {
    'pass': pass,
    'parses': parses,
    'rendered': rendered,
    'bytes': bytes,
    'paths': paths,
    'problems': problems,
  };
}

/// Pulls the SVG out of a model reply: the last ```svg fence, else the first
/// `<svg …</svg>` span. Null when there is none.
String? extractSvg(String text) {
  final fences = RegExp(r'```(?:svg|xml)?\s*\n([\s\S]*?)```').allMatches(text).toList().reversed;
  for (final m in fences) {
    final body = m.group(1)!.trim();
    if (body.contains('<svg')) return body;
  }
  final start = text.indexOf('<svg');
  final end = text.lastIndexOf('</svg>');
  if (start >= 0 && end > start) return text.substring(start, end + 6);
  return null;
}

const _banned = ['script', 'foreignObject', 'iframe', 'image'];

/// Structural check without an XML dependency: a tag scanner with a stack.
GateResult checkStructure(String svg) {
  final problems = <String>[];
  final trimmed = svg.trim();
  final tag = RegExp(
    r'<(/?)([A-Za-z][\w:.-]*)((?:"[^"]*"|'
    "'[^']*'"
    r'|[^>"'
    "'"
    r'])*?)(/?)>',
  );
  final stack = <String>[];
  String? root;
  var paths = 0;
  var ok = true;
  // Strip comments, CDATA and the XML prolog before scanning.
  final cleaned = trimmed
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(RegExp(r'<!\[CDATA\[[\s\S]*?\]\]>'), '')
      .replaceAll(RegExp(r'<\?[\s\S]*?\?>'), '')
      .replaceAll(RegExp(r'<!DOCTYPE[^>]*>'), '');
  for (final m in tag.allMatches(cleaned)) {
    final closing = m.group(1) == '/';
    final name = m.group(2)!;
    final attrs = m.group(3) ?? '';
    final selfClosing = m.group(4) == '/';
    if (!closing) {
      root ??= name;
      if (name == 'path') paths++;
      if (_banned.contains(name)) problems.add('disallowed element <$name>');
      if (RegExp(r'\son\w+\s*=', caseSensitive: false).hasMatch(' $attrs')) problems.add('event attribute on <$name>');
      if (RegExp(r'(?:xlink:)?href\s*=\s*["\x27]\s*(?:https?:)?//', caseSensitive: false).hasMatch(attrs)) {
        problems.add('external reference on <$name>');
      }
      if (!selfClosing) stack.add(name);
    } else {
      if (stack.isEmpty || stack.last != name) {
        problems.add('mismatched </$name>');
        ok = false;
        break;
      }
      stack.removeLast();
    }
  }
  if (root != 'svg') {
    problems.add('root element is ${root ?? 'missing'}, not svg');
    ok = false;
  }
  if (ok && stack.isNotEmpty) {
    problems.add('unclosed <${stack.last}>');
    ok = false;
  }
  if (ok && !RegExp(r'<svg[^>]*\sxmlns\s*=').hasMatch(cleaned)) problems.add('missing xmlns');
  if (ok && !RegExp(r'<svg[^>]*\sviewBox\s*=').hasMatch(cleaned)) problems.add('missing viewBox');
  final hard = problems.any((p) => p.startsWith('disallowed') || p.startsWith('event') || p.startsWith('external'));
  return GateResult(parses: ok && !hard, problems: problems, bytes: trimmed.length, paths: paths);
}

/// Whether `rsvg-convert` is on PATH.
Future<bool> hasRsvg() async {
  try {
    return (await Process.run('rsvg-convert', ['--version'])).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Rasterizes [svg] to PNG bytes at [width] px, or null if it fails.
Future<List<int>?> rasterize(String svg, {int width = 768}) async {
  try {
    final p = await Process.start('rsvg-convert', ['-w', '$width', '-f', 'png']);
    p.stdin.write(svg);
    await p.stdin.close();
    final out = <int>[];
    await for (final chunk in p.stdout) {
      out.addAll(chunk);
    }
    await p.stderr.drain<void>();
    return await p.exitCode == 0 && out.isNotEmpty ? out : null;
  } on ProcessException {
    return null;
  }
}

/// Structure check plus, when [rsvg] is true, a real rasterization.
Future<GateResult> runGate(String svg, {required bool rsvg}) async {
  final s = checkStructure(svg);
  if (!s.parses || !rsvg) return s;
  final png = await rasterize(svg);
  final problems = [...s.problems, if (png == null) 'rsvg-convert failed'];
  return GateResult(parses: true, rendered: png != null, problems: problems, bytes: s.bytes, paths: s.paths);
}
