import 'package:flutter/widgets.dart';

import 'code/syntax_themes.dart';

/// Monospace font stack used by the fallback styles.
const String _monoFamily = 'monospace';
const List<String> _monoFallback = <String>[
  'SF Mono',
  'Menlo',
  'JetBrains Mono',
  'Cascadia Mono',
  'Consolas',
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
    this.inlineCodeBackground = const Color(0x1F818B98),
    this.inlineCodeBorder = const Color(0x33818B98),
    this.codeHeaderBackground = const Color(0x0F818B98),
    this.tableHeaderBackground = const Color(0x14818B98),
    this.tableStripe = const Color(0x0A818B98),
    this.citationBackground = const Color(0x264493F8),
    this.citationText = const Color(0xFF2F6FCF),
  });

  /// Neutral defaults for the given [brightness]: GitHub-like text styling,
  /// One Dark / GitHub syntax colors, and chat-app style inline code and
  /// citation chips. Text styles inherit the ambient font family.
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
      // Warm amber on slate (dark, 7.8:1) / plum on lavender (light, 5.7:1).
      inlineCode: mono.copyWith(fontSize: 13, color: dark ? const Color(0xFFE6C07B) : const Color(0xFF9A3D6A)),
      codeBlock: mono.copyWith(
        fontSize: 13,
        height: 1.5,
        color: dark ? const Color(0xFFC9CED6) : const Color(0xFF1F2328),
      ),
      blockquote: body.copyWith(color: muted),
      tableHeader: body.copyWith(fontWeight: FontWeight.w600),
      tableCell: body,
      // No underline at rest; links underline while hovered.
      link: TextStyle(color: dark ? const Color(0xFF58A6FF) : const Color(0xFF0969DA)),
      codeBlockBackground: dark ? const Color(0xFF1E2127) : const Color(0xFFF6F8FA),
      codeBlockBorder: dark ? const Color(0xFF30353E) : const Color(0xFFDDE2E8),
      blockquoteBar: dark ? const Color(0xFF4A515C) : const Color(0xFFD0D7DE),
      tableBorder: border,
      ruleColor: border,
      selection: dark ? const Color(0x664493F8) : const Color(0x400969DA),
      syntaxTheme: dark ? darkSyntaxTheme : lightSyntaxTheme,
      codeBlockRadius: 12,
      inlineCodeBackground: dark ? const Color(0xFF2B2F3A) : const Color(0xFFF1EFF7),
      inlineCodeBorder: dark ? const Color(0xFF3A3F4C) : const Color(0xFFE2DFEA),
      codeHeaderBackground: dark ? const Color(0xFF282C34) : const Color(0xFFEDF0F4),
      tableHeaderBackground: dark ? const Color(0x14FFFFFF) : const Color(0x0D1F2328),
      tableStripe: dark ? const Color(0x08FFFFFF) : const Color(0x061F2328),
      citationBackground: dark ? const Color(0xFF23324A) : const Color(0xFFE5EDFB),
      citationText: dark ? const Color(0xFF8AB4F8) : const Color(0xFF1F5BC1),
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
  ///
  /// Short spans render as a chip filled with [inlineCodeBackground] and
  /// outlined with [inlineCodeBorder]; a `backgroundColor` set here is
  /// ignored for chips and only used as a fallback fill for long spans.
  final TextStyle inlineCode;

  /// Base text style of fenced / indented code blocks.
  final TextStyle codeBlock;

  /// Text style for content inside block quotes.
  final TextStyle blockquote;
  final TextStyle tableHeader;
  final TextStyle tableCell;

  /// Merged on top of the surrounding text for links. An underline is added
  /// while a link is hovered.
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

  /// Corner radius of code blocks (tables use a slightly smaller one).
  final double codeBlockRadius;

  /// Fill of the inline code chip.
  final Color inlineCodeBackground;

  /// Hairline border of the inline code chip.
  final Color inlineCodeBorder;

  /// Background of a code block's header bar (language label, buttons).
  final Color codeHeaderBackground;

  /// Background of table header rows.
  final Color tableHeaderBackground;

  /// Background of every other table body row.
  final Color tableStripe;

  /// Fill of the default citation chip (`[1]`).
  final Color citationBackground;

  /// Text color of the default citation chip.
  final Color citationText;

  /// Syntax highlighting styles keyed by highlight.js scope (`keyword`,
  /// `string`, `comment`, `number`, `title`, `title.function`, ...).
  ///
  /// Dotted scopes fall back to their prefix: `title.class` uses `title`
  /// when it has no entry of its own. highlight.js CSS-style keys with a
  /// trailing underscore (`title.class_`) are accepted too.
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
    Color? inlineCodeBackground,
    Color? inlineCodeBorder,
    Color? codeHeaderBackground,
    Color? tableHeaderBackground,
    Color? tableStripe,
    Color? citationBackground,
    Color? citationText,
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
      inlineCodeBackground: inlineCodeBackground ?? this.inlineCodeBackground,
      inlineCodeBorder: inlineCodeBorder ?? this.inlineCodeBorder,
      codeHeaderBackground: codeHeaderBackground ?? this.codeHeaderBackground,
      tableHeaderBackground: tableHeaderBackground ?? this.tableHeaderBackground,
      tableStripe: tableStripe ?? this.tableStripe,
      citationBackground: citationBackground ?? this.citationBackground,
      citationText: citationText ?? this.citationText,
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
        other.inlineCodeBackground == inlineCodeBackground &&
        other.inlineCodeBorder == inlineCodeBorder &&
        other.codeHeaderBackground == codeHeaderBackground &&
        other.tableHeaderBackground == tableHeaderBackground &&
        other.tableStripe == tableStripe &&
        other.citationBackground == citationBackground &&
        other.citationText == citationText &&
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
    inlineCodeBackground,
    inlineCodeBorder,
    codeHeaderBackground,
    tableHeaderBackground,
    tableStripe,
    citationBackground,
    citationText,
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

  /// One Dark-inspired syntax colors (dark backgrounds).
  static const Map<String, TextStyle> darkSyntaxTheme = oneDarkSyntaxTheme;

  /// GitHub-inspired syntax colors (light backgrounds).
  static const Map<String, TextStyle> lightSyntaxTheme = githubLightSyntaxTheme;
}

/// Provides the active [MarkdownStyle] to custom builders below a
/// `MarkdownView`. Read it with [MarkdownStyle.of].
class MarkdownStyleScope extends InheritedWidget {
  const MarkdownStyleScope({super.key, required this.style, required super.child});

  final MarkdownStyle style;

  @override
  bool updateShouldNotify(MarkdownStyleScope oldWidget) => style != oldWidget.style;
}
