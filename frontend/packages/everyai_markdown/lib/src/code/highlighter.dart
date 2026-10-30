import 'package:flutter/widgets.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

/// Syntax highlighting for code blocks, backed by re_highlight.
abstract final class CodeHighlighter {
  static final Highlight _highlight = Highlight()
    ..registerLanguages(<String, Mode>{
      'dart': langDart,
      'python': langPython,
      'javascript': langJavascript,
      'typescript': langTypescript,
      'json': langJson,
      'bash': langBash,
      'shell': langShell,
      'yaml': langYaml,
      'xml': langXml,
      'css': langCss,
      'sql': langSql,
      'go': langGo,
      'rust': langRust,
      'kotlin': langKotlin,
      'swift': langSwift,
      'java': langJava,
      'c': langC,
      'cpp': langCpp,
      'csharp': langCsharp,
      'markdown': langMarkdown,
    });

  /// Extra aliases on top of the grammars' own (`js`, `py`, `yml`, ...).
  static const Map<String, String> _aliases = <String, String>{
    // Fences labelled `shell`/`zsh` almost always contain plain commands,
    // which the bash grammar handles; `console` keeps the session grammar.
    'shell': 'bash',
    'sh': 'bash',
    'zsh': 'bash',
    'console': 'shell',
    'shellsession': 'shell',
    'html': 'xml',
    'htm': 'xml',
    'svg': 'xml',
    'xhtml': 'xml',
    'jsonc': 'json',
    'json5': 'json',
    'golang': 'go',
    'objective-c': 'c',
    'h': 'c',
    'c#': 'csharp',
    'cs': 'csharp',
    'kt': 'kotlin',
    'py': 'python',
    'python3': 'python',
    'ts': 'typescript',
    'tsx': 'typescript',
    'js': 'javascript',
    'jsx': 'javascript',
    'node': 'javascript',
    'md': 'markdown',
    'rs': 'rust',
    'yml': 'yaml',
    'postgres': 'sql',
    'postgresql': 'sql',
    'mysql': 'sql',
    'sqlite': 'sql',
  };

  /// The registered grammar name for [language], or `null` if unsupported.
  static String? resolve(String? language) {
    if (language == null) return null;
    final lower = language.trim().toLowerCase();
    if (lower.isEmpty) return null;
    final name = _aliases[lower] ?? lower;
    return _highlight.getLanguage(name) == null ? null : name;
  }

  /// Highlights [code] as [language]. Unsupported languages and grammar
  /// failures produce a single unstyled span.
  static TextSpan highlight(
    String code,
    String? language, {
    required TextStyle base,
    required Map<String, TextStyle> theme,
  }) {
    final name = resolve(language);
    if (name == null || code.isEmpty) return TextSpan(text: code, style: base);
    try {
      final result = _highlight.highlight(code: code, language: name);
      final renderer = _ThemedSpanRenderer(theme);
      result.render(renderer);
      return TextSpan(style: base, children: renderer.result);
    } on Object {
      return TextSpan(text: code, style: base);
    }
  }
}

/// Builds nested [TextSpan]s from the highlight token tree, resolving dotted
/// scopes (`title.function_`) to their closest themed prefix (`title`).
class _ThemedSpanRenderer implements HighlightRenderer {
  _ThemedSpanRenderer(this.theme);

  final Map<String, TextStyle> theme;
  final List<List<InlineSpan>> _stack = <List<InlineSpan>>[<InlineSpan>[]];
  final List<TextStyle?> _styles = <TextStyle?>[];

  List<InlineSpan> get result => _stack.first;

  TextStyle? _resolve(String? scope) {
    if (scope == null) return null;
    var key = scope;
    while (true) {
      final style = theme[key];
      if (style != null) return style;
      final dot = key.lastIndexOf('.');
      if (dot <= 0) return null;
      key = key.substring(0, dot);
    }
  }

  @override
  void addText(String text) => _stack.last.add(TextSpan(text: text));

  @override
  void openNode(DataNode node) {
    _stack.add(<InlineSpan>[]);
    _styles.add(_resolve(node.scope));
  }

  @override
  void closeNode(DataNode node) {
    final children = _stack.removeLast();
    final style = _styles.removeLast();
    if (children.isEmpty) return;
    if (style == null && _stack.length > 1) {
      _stack.last.addAll(children);
    } else {
      _stack.last.add(TextSpan(style: style, children: children));
    }
  }
}
