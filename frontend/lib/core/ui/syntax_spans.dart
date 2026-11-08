import 'dart:convert';

import 'package:everyai_markdown/everyai_markdown.dart';
import 'package:flutter/widgets.dart';

/// Light syntax coloring for tool rows, diffs and edit cards, on top of the
/// markdown package's highlighter.

/// The syntax palette for [brightness] (the same one chat code blocks use).
Map<String, TextStyle> syntaxThemeFor(Brightness brightness) =>
    brightness == Brightness.dark ? oneDarkSyntaxTheme : githubLightSyntaxTheme;

/// Highlights [code] as [language] (`null` or unknown gives one plain span).
/// Results are cached, since rows rebuild while a session runs.
TextSpan codeSpan(String code, String? language, {required TextStyle base, required Brightness brightness}) {
  if (language == null || code.isEmpty) return TextSpan(text: code, style: base);
  final key = (code, language, base, brightness);
  final hit = _cache.remove(key);
  if (hit != null) return _cache[key] = hit;
  final span = CodeHighlighter.highlight(code, language, base: base, theme: syntaxThemeFor(brightness));
  // A big block isn't kept: while one streams in, every frame is a new, longer text, and keeping each one's spans
  // took hundreds of MB for one written file.
  if (code.length > syntaxCacheEntryChars) return span;
  _cache[key] = span;
  _cachedChars += code.length;
  while (_cache.length > _cacheSize || _cachedChars > syntaxCacheChars) {
    final oldest = _cache.keys.first;
    _cache.remove(oldest);
    _cachedChars -= oldest.$1.length;
  }
  return span;
}

const _cacheSize = 600;

/// The most code the cache holds, in characters (its spans take ~10 KB per KB of code).
const syntaxCacheChars = 256 * 1024;

/// Longer code is highlighted but not kept.
const syntaxCacheEntryChars = 8 * 1024;
final _cache = <(String, String, TextStyle, Brightness), TextSpan>{};
var _cachedChars = 0;

/// How many characters of code the cache holds now (tests).
@visibleForTesting
int get syntaxCachedChars => _cachedChars;

@visibleForTesting
void clearSyntaxCache() {
  _cache.clear();
  _cachedChars = 0;
}

/// A shell command, colored.
TextSpan shellSpan(String command, {required TextStyle base, required Brightness brightness}) =>
    codeSpan(command, 'bash', base: base, brightness: brightness);

/// A path with its folder dimmed, so the file name stands out.
TextSpan pathSpan(String path, {required TextStyle base, required Color muted}) {
  final slash = path.lastIndexOf('/');
  if (slash < 0 || slash == path.length - 1) return TextSpan(text: path, style: base);
  return TextSpan(
    style: base,
    children: [
      TextSpan(
        text: path.substring(0, slash + 1),
        style: TextStyle(color: muted),
      ),
      TextSpan(text: path.substring(slash + 1)),
    ],
  );
}

/// Whether [text] is a JSON object or array (worth coloring as JSON).
bool looksLikeJson(String text) {
  final t = text.trim();
  if (t.length < 2) return false;
  final open = t[0], close = t[t.length - 1];
  if (!((open == '{' && close == '}') || (open == '[' && close == ']'))) return false;
  if (t.length > 200000) return true; // too big to parse on every build; trust the brackets
  try {
    jsonDecode(t);
    return true;
  } on FormatException {
    return false;
  }
}

/// Tool output: JSON gets colored, anything else stays plain.
TextSpan outputSpan(String text, {required TextStyle base, required Brightness brightness}) => looksLikeJson(text)
    ? codeSpan(text, 'json', base: base, brightness: brightness)
    : TextSpan(text: text, style: base);

/// A tool's arguments as indented, colored JSON (without its `kind` tag).
TextSpan argumentsSpan(Map<String, Object?> args, {required TextStyle base, required Brightness brightness}) {
  final shown = Map.of(args)..remove('kind');
  final text = JsonEncoder.withIndent('  ', (o) => '$o').convert(shown);
  return codeSpan(text, 'json', base: base, brightness: brightness);
}

/// The last non-empty line of [text], trimmed, for a one-line preview.
String lastLine(String text) {
  final lines = text.trimRight().split('\n');
  for (final l in lines.reversed) {
    if (l.trim().isNotEmpty) return l.trim();
  }
  return '';
}
