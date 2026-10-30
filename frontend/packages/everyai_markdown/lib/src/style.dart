import 'package:flutter/widgets.dart';

/// Monospace font stack used by the fallback styles.
const String _monoFamily = 'monospace';
const List<String> _monoFallback = <String>[
  'Menlo',
  'SF Mono',
  'Consolas',
  'Cascadia Mono',
  'Roboto Mono',
  'DejaVu Sans Mono',
  'Ubuntu Mono',
  'Liberation Mono',
  'Courier New',
];

/// Visual configuration for `MarkdownView`.
///
/// The renderer is design-system neutral: every color, text style and
/// spacing comes from this object. Apps typically derive one from their
/// Material / Cupertino / Fluent / Yaru theme and pass it in, or start from
/// [MarkdownStyle.fallback] and [copyWith] what differs.
@immutable
class MarkdownStyle {
  const MarkdownStyle({
    required this.body,
    required this.h1,
    required this.h2,
    required this.h3,
    required this.h4,
    required this.h5,
    required this.h6,
    required this.inlineCode,
    required this.codeBlock,
    required this.blockquote,
    required this.tableHeader,
    required this.tableCell,
    required this.link,
    required this.codeBlockBackground,
    required this.codeBlockBorder,
    required this.blockquoteBar,
    required this.tableBorder,
    required this.ruleColor,
    required this.selection,
    required this.syntaxTheme,
    this.blockSpacing = 12,
    this.listIndent = 24,
    this.codeBlockRadius = 8,
  });

  /// Neutral defaults for the given [brightness], loosely following GitHub's
  /// Markdown styling. Text styles inherit the ambient font family.
  factory MarkdownStyle.fallback(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final text = dark ? const Color(0xFFE6EDF3) : const Color(0xFF1F2328);
    final muted = dark ? const Color(0xFF9198A1) : const Color(0xFF59636E);
    final border = dark ? const Color(0xFF3D444D) : const Color(0xFFD1D9E0);
    final body = TextStyle(fontSize: 15, height: 1.5, color: text);
    TextStyle heading(double size, {FontWeight weight = FontWeight.w600}) =>
        body.copyWith(fontSize: size, fontWeight: weight, height: 1.25);
    const mono = TextStyle(fontFamily: _monoFamily, fontFamilyFallback: _monoFallback);
    return MarkdownStyle(
      body: body,
      h1: heading(28),
      h2: heading(23),
      h3: heading(19),
      h4: heading(16),
      h5: heading(15),
      h6: heading(14).copyWith(color: muted),
      inlineCode: mono.copyWith(
        fontSize: 13.5,
        backgroundColor: dark ? const Color(0x33656C76) : const Color(0x33818B98),
      ),
      codeBlock: mono.copyWith(fontSize: 13.5, height: 1.45, color: text),
      blockquote: body.copyWith(color: muted),
      tableHeader: body.copyWith(fontWeight: FontWeight.w600),
      tableCell: body,
      link: TextStyle(
        color: dark ? const Color(0xFF4493F8) : const Color(0xFF0969DA),
        decoration: TextDecoration.underline,
        decorationColor: dark ? const Color(0x804493F8) : const Color(0x800969DA),
      ),
      codeBlockBackground: dark ? const Color(0xFF151B23) : const Color(0xFFF6F8FA),
      codeBlockBorder: border,
      blockquoteBar: border,
      tableBorder: border,
      ruleColor: border,
      selection: dark ? const Color(0x664493F8) : const Color(0x400969DA),
      syntaxTheme: dark ? darkSyntaxTheme : lightSyntaxTheme,
    );
  }

  /// Paragraph text.
  final TextStyle body;
  final TextStyle h1;
  final TextStyle h2;
  final TextStyle h3;
  final TextStyle h4;
  final TextStyle h5;
  final TextStyle h6;

  /// Merged on top of the surrounding text for `inline code`.
  final TextStyle inlineCode;

  /// Base text style of fenced / indented code blocks.
  final TextStyle codeBlock;

  /// Text style for content inside block quotes.
  final TextStyle blockquote;
  final TextStyle tableHeader;
  final TextStyle tableCell;

  /// Merged on top of the surrounding text for links.
  final TextStyle link;

  final Color codeBlockBackground;
  final Color codeBlockBorder;
  final Color blockquoteBar;
  final Color tableBorder;
  final Color ruleColor;

  /// Selection highlight color (applied via `DefaultSelectionStyle`).
  final Color selection;

  /// Vertical gap between top-level blocks.
  final double blockSpacing;

  /// Width reserved for list markers.
  final double listIndent;

  /// Corner radius of code blocks.
  final double codeBlockRadius;

  /// Syntax highlighting styles keyed by highlight.js scope (`keyword`,
  /// `string`, `comment`, `number`, `title`, `title.function_`, ...).
  ///
  /// Dotted scopes fall back to their prefix: `title.class_` uses `title`
  /// when it has no entry of its own.
  final Map<String, TextStyle> syntaxTheme;

  /// The heading style for [level] (1-6).
  TextStyle heading(int level) => switch (level) {
    1 => h1,
    2 => h2,
    3 => h3,
    4 => h4,
    5 => h5,
    _ => h6,
  };

  /// The style provided by the nearest `MarkdownView`, if any.
  static MarkdownStyle? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MarkdownStyleScope>()?.style;

  /// The style provided by the nearest `MarkdownView`, or a fallback that
  /// follows the platform brightness.
  static MarkdownStyle of(BuildContext context) =>
      maybeOf(context) ?? MarkdownStyle.fallback(MediaQuery.maybePlatformBrightnessOf(context) ?? Brightness.light);

  MarkdownStyle copyWith({
    TextStyle? body,
    TextStyle? h1,
    TextStyle? h2,
    TextStyle? h3,
    TextStyle? h4,
    TextStyle? h5,
    TextStyle? h6,
    TextStyle? inlineCode,
    TextStyle? codeBlock,
    TextStyle? blockquote,
    TextStyle? tableHeader,
    TextStyle? tableCell,
    TextStyle? link,
    Color? codeBlockBackground,
    Color? codeBlockBorder,
    Color? blockquoteBar,
    Color? tableBorder,
    Color? ruleColor,
    Color? selection,
    double? blockSpacing,
    double? listIndent,
    double? codeBlockRadius,
    Map<String, TextStyle>? syntaxTheme,
  }) {
    return MarkdownStyle(
      body: body ?? this.body,
      h1: h1 ?? this.h1,
      h2: h2 ?? this.h2,
      h3: h3 ?? this.h3,
      h4: h4 ?? this.h4,
      h5: h5 ?? this.h5,
      h6: h6 ?? this.h6,
      inlineCode: inlineCode ?? this.inlineCode,
      codeBlock: codeBlock ?? this.codeBlock,
      blockquote: blockquote ?? this.blockquote,
      tableHeader: tableHeader ?? this.tableHeader,
      tableCell: tableCell ?? this.tableCell,
      link: link ?? this.link,
      codeBlockBackground: codeBlockBackground ?? this.codeBlockBackground,
      codeBlockBorder: codeBlockBorder ?? this.codeBlockBorder,
      blockquoteBar: blockquoteBar ?? this.blockquoteBar,
      tableBorder: tableBorder ?? this.tableBorder,
      ruleColor: ruleColor ?? this.ruleColor,
      selection: selection ?? this.selection,
      blockSpacing: blockSpacing ?? this.blockSpacing,
      listIndent: listIndent ?? this.listIndent,
      codeBlockRadius: codeBlockRadius ?? this.codeBlockRadius,
      syntaxTheme: syntaxTheme ?? this.syntaxTheme,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MarkdownStyle &&
        other.body == body &&
        other.h1 == h1 &&
        other.h2 == h2 &&
        other.h3 == h3 &&
        other.h4 == h4 &&
        other.h5 == h5 &&
        other.h6 == h6 &&
        other.inlineCode == inlineCode &&
        other.codeBlock == codeBlock &&
        other.blockquote == blockquote &&
        other.tableHeader == tableHeader &&
        other.tableCell == tableCell &&
        other.link == link &&
        other.codeBlockBackground == codeBlockBackground &&
        other.codeBlockBorder == codeBlockBorder &&
        other.blockquoteBar == blockquoteBar &&
        other.tableBorder == tableBorder &&
        other.ruleColor == ruleColor &&
        other.selection == selection &&
        other.blockSpacing == blockSpacing &&
        other.listIndent == listIndent &&
        other.codeBlockRadius == codeBlockRadius &&
        _mapEquals(other.syntaxTheme, syntaxTheme);
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
    body,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    inlineCode,
    codeBlock,
    blockquote,
    tableHeader,
    tableCell,
    link,
    codeBlockBackground,
    codeBlockBorder,
    blockquoteBar,
    tableBorder,
    ruleColor,
    selection,
    blockSpacing,
    listIndent,
    codeBlockRadius,
    syntaxTheme.length,
  ]);

  static bool _mapEquals(Map<String, TextStyle> a, Map<String, TextStyle> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// GitHub-dark-inspired syntax colors.
  static const Map<String, TextStyle> darkSyntaxTheme = <String, TextStyle>{
    'keyword': TextStyle(color: Color(0xFFFF7B72)),
    'doctag': TextStyle(color: Color(0xFFFF7B72)),
    'template-tag': TextStyle(color: Color(0xFFFF7B72)),
    'template-variable': TextStyle(color: Color(0xFFFF7B72)),
    'type': TextStyle(color: Color(0xFFFF7B72)),
    'variable.language_': TextStyle(color: Color(0xFFFF7B72)),
    'title': TextStyle(color: Color(0xFFD2A8FF)),
    'title.class_': TextStyle(color: Color(0xFFFFA657)),
    'title.function_': TextStyle(color: Color(0xFFD2A8FF)),
    'attr': TextStyle(color: Color(0xFF79C0FF)),
    'attribute': TextStyle(color: Color(0xFF79C0FF)),
    'literal': TextStyle(color: Color(0xFF79C0FF)),
    'meta': TextStyle(color: Color(0xFF79C0FF)),
    'number': TextStyle(color: Color(0xFF79C0FF)),
    'operator': TextStyle(color: Color(0xFF79C0FF)),
    'variable': TextStyle(color: Color(0xFF79C0FF)),
    'selector-attr': TextStyle(color: Color(0xFF79C0FF)),
    'selector-class': TextStyle(color: Color(0xFF79C0FF)),
    'selector-id': TextStyle(color: Color(0xFF79C0FF)),
    'built_in': TextStyle(color: Color(0xFFFFA657)),
    'symbol': TextStyle(color: Color(0xFFFFA657)),
    'regexp': TextStyle(color: Color(0xFFA5D6FF)),
    'string': TextStyle(color: Color(0xFFA5D6FF)),
    'meta.string': TextStyle(color: Color(0xFFA5D6FF)),
    'subst': TextStyle(color: Color(0xFFC9D1D9)),
    'params': TextStyle(color: Color(0xFFC9D1D9)),
    'comment': TextStyle(color: Color(0xFF8B949E), fontStyle: FontStyle.italic),
    'code': TextStyle(color: Color(0xFF8B949E)),
    'formula': TextStyle(color: Color(0xFF8B949E)),
    'name': TextStyle(color: Color(0xFF7EE787)),
    'quote': TextStyle(color: Color(0xFF7EE787)),
    'selector-tag': TextStyle(color: Color(0xFF7EE787)),
    'selector-pseudo': TextStyle(color: Color(0xFF7EE787)),
    'section': TextStyle(color: Color(0xFF1F6FEB), fontWeight: FontWeight.bold),
    'bullet': TextStyle(color: Color(0xFFF2CC60)),
    'emphasis': TextStyle(fontStyle: FontStyle.italic),
    'strong': TextStyle(fontWeight: FontWeight.bold),
    'addition': TextStyle(color: Color(0xFFAFF5B4)),
    'deletion': TextStyle(color: Color(0xFFFFDCD7)),
    'property': TextStyle(color: Color(0xFF79C0FF)),
    'tag': TextStyle(color: Color(0xFF7EE787)),
  };

  /// GitHub-light-inspired syntax colors.
  static const Map<String, TextStyle> lightSyntaxTheme = <String, TextStyle>{
    'keyword': TextStyle(color: Color(0xFFCF222E)),
    'doctag': TextStyle(color: Color(0xFFCF222E)),
    'template-tag': TextStyle(color: Color(0xFFCF222E)),
    'template-variable': TextStyle(color: Color(0xFFCF222E)),
    'type': TextStyle(color: Color(0xFFCF222E)),
    'variable.language_': TextStyle(color: Color(0xFFCF222E)),
    'title': TextStyle(color: Color(0xFF8250DF)),
    'title.class_': TextStyle(color: Color(0xFF953800)),
    'title.function_': TextStyle(color: Color(0xFF8250DF)),
    'attr': TextStyle(color: Color(0xFF0550AE)),
    'attribute': TextStyle(color: Color(0xFF0550AE)),
    'literal': TextStyle(color: Color(0xFF0550AE)),
    'meta': TextStyle(color: Color(0xFF0550AE)),
    'number': TextStyle(color: Color(0xFF0550AE)),
    'operator': TextStyle(color: Color(0xFF0550AE)),
    'variable': TextStyle(color: Color(0xFF0550AE)),
    'selector-attr': TextStyle(color: Color(0xFF0550AE)),
    'selector-class': TextStyle(color: Color(0xFF0550AE)),
    'selector-id': TextStyle(color: Color(0xFF0550AE)),
    'built_in': TextStyle(color: Color(0xFF953800)),
    'symbol': TextStyle(color: Color(0xFF953800)),
    'regexp': TextStyle(color: Color(0xFF0A3069)),
    'string': TextStyle(color: Color(0xFF0A3069)),
    'meta.string': TextStyle(color: Color(0xFF0A3069)),
    'subst': TextStyle(color: Color(0xFF1F2328)),
    'params': TextStyle(color: Color(0xFF1F2328)),
    'comment': TextStyle(color: Color(0xFF59636E), fontStyle: FontStyle.italic),
    'code': TextStyle(color: Color(0xFF59636E)),
    'formula': TextStyle(color: Color(0xFF59636E)),
    'name': TextStyle(color: Color(0xFF116329)),
    'quote': TextStyle(color: Color(0xFF116329)),
    'selector-tag': TextStyle(color: Color(0xFF116329)),
    'selector-pseudo': TextStyle(color: Color(0xFF116329)),
    'section': TextStyle(color: Color(0xFF0550AE), fontWeight: FontWeight.bold),
    'bullet': TextStyle(color: Color(0xFF953800)),
    'emphasis': TextStyle(fontStyle: FontStyle.italic),
    'strong': TextStyle(fontWeight: FontWeight.bold),
    'addition': TextStyle(color: Color(0xFF116329)),
    'deletion': TextStyle(color: Color(0xFF82071E)),
    'property': TextStyle(color: Color(0xFF0550AE)),
    'tag': TextStyle(color: Color(0xFF116329)),
  };
}

/// Provides the active [MarkdownStyle] to custom builders below a
/// `MarkdownView`. Read it with [MarkdownStyle.of].
class MarkdownStyleScope extends InheritedWidget {
  const MarkdownStyleScope({super.key, required this.style, required super.child});

  final MarkdownStyle style;

  @override
  bool updateShouldNotify(MarkdownStyleScope oldWidget) => style != oldWidget.style;
}
