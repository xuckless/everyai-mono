import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_math_fork/tex.dart';

/// One TeX expression found in Markdown.
typedef MathSpan = ({String tex, bool display});

// The delimiters the chat renderer understands, in its order: $$…$$, \[…\],
// \(…\), then $…$ with the currency rules (no space inside the dollars, no
// digit right after the closing one).
final _math = RegExp(
  r'\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\)|\$(?![\s$])((?:\\.|[^\\$\n])*?[^\s\\$])\$(?!\d)',
);
final _fence = RegExp(r'^\s{0,3}(`{3,}|~{3,})\s*([\w+-]*)');
final _inlineCode = RegExp(r'(`+)[\s\S]*?\1');

/// Every math expression in [markdown], in order: ```math / ```latex / ```tex
/// fences and the inline and display delimiters outside code.
List<MathSpan> mathIn(String markdown) {
  final out = <MathSpan>[];
  final prose = StringBuffer();
  void scan() {
    final text = prose.toString().replaceAllMapped(_inlineCode, (m) => ' ' * m[0]!.length);
    for (final m in _math.allMatches(text)) {
      final (tex, display) = m[1] != null
          ? (m[1]!, true)
          : m[2] != null
          ? (m[2]!, true)
          : m[3] != null
          ? (m[3]!, false)
          : (m[4]!, false);
      if (tex.trim().isNotEmpty) out.add((tex: tex.trim(), display: display));
    }
    prose.clear();
  }

  final lines = markdown.replaceAll('\r\n', '\n').split('\n');
  for (var i = 0; i < lines.length; i++) {
    final open = _fence.firstMatch(lines[i]);
    if (open == null) {
      prose.writeln(lines[i]);
      continue;
    }
    scan();
    final marker = open[1]!;
    final body = <String>[];
    var j = i + 1;
    for (; j < lines.length && !lines[j].trimLeft().startsWith(marker); j++) {
      body.add(lines[j]);
    }
    if (const {'math', 'latex', 'tex'}.contains(open[2]!.toLowerCase()) && body.join().trim().isNotEmpty) {
      out.add((tex: body.join('\n').trim(), display: true));
    }
    i = j;
  }
  scan();
  return out;
}

/// Why flutter_math (the app's renderer) can't parse [tex]; null when it can.
String? texError(String tex) {
  try {
    TexParser(tex, const TexParserSettings()).parse();
    return null;
  } on ParseException catch (e) {
    return e.message;
  } on Object catch (e) {
    return '$e';
  }
}

/// The math in [markdown] the app can't draw, as "`tex`: why" lines.
List<String> mathProblems(String markdown, {int max = 8}) {
  final out = <String>[];
  for (final span in mathIn(markdown)) {
    final error = texError(span.tex);
    if (error == null) continue;
    final tex = span.tex.length > 120 ? '${span.tex.substring(0, 120)}…' : span.tex;
    out.add('`$tex`: $error');
    if (out.length == max) break;
  }
  return out;
}
