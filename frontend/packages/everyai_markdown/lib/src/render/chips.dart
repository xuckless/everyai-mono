import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../style.dart';

/// Builds the widget for a citation marker such as `[1]`.
///
/// The widget is placed inline, baseline-aligned, with the surrounding text
/// style available through `DefaultTextStyle.of(context)`. Taps are handled
/// by `MarkdownView.onTapCitation`; the builder only provides visuals.
typedef CitationBuilder = Widget Function(BuildContext context, int index);

/// The default [CitationBuilder]: a [CitationChip].
Widget defaultCitationBuilder(BuildContext context, int index) => CitationChip(index: index);

/// A small rounded, accent-tinted chip showing a citation number, sized
/// relative to the surrounding text and nudged up like a superscript.
class CitationChip extends StatelessWidget {
  const CitationChip({super.key, required this.index, this.style});

  final int index;

  /// Defaults to the enclosing `MarkdownView`'s style.
  final MarkdownStyle? style;

  @override
  Widget build(BuildContext context) {
    final style = this.style ?? MarkdownStyle.of(context);
    final ambient = DefaultTextStyle.of(context).style;
    final size = ambient.fontSize ?? style.body.fontSize ?? 15;
    final fontSize = math.max(10.0, size * 0.7);
    return Transform.translate(
      offset: Offset(0, -size * 0.2),
      child: Container(
        constraints: BoxConstraints(minWidth: fontSize * 1.55),
        padding: EdgeInsets.symmetric(horizontal: fontSize * 0.42, vertical: 0.5),
        decoration: BoxDecoration(color: style.citationBackground, borderRadius: BorderRadius.circular(fontSize * 0.5)),
        child: Text(
          '$index',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: ambient.fontFamily,
            fontFamilyFallback: ambient.fontFamilyFallback,
            fontSize: fontSize,
            height: 1.25,
            fontWeight: FontWeight.w600,
            color: style.citationText,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// Wraps a citation widget: excludes it from text selection (so copied text
/// reads naturally), adds a small gap, semantics and tap handling.
class CitationTarget extends StatelessWidget {
  const CitationTarget({super.key, required this.index, required this.onTap, required this.child});

  final int index;
  final ValueChanged<int>? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final onTap = this.onTap;
    Widget result = Padding(padding: const EdgeInsets.only(left: 2, right: 1), child: child);
    if (onTap != null) {
      result = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => onTap(index), child: result),
      );
    }
    return SelectionContainer.disabled(
      child: Semantics(button: onTap != null, label: 'Citation $index', excludeSemantics: true, child: result),
    );
  }
}

/// `inline code` rendered as a rounded chip with a fill and hairline border.
///
/// The text is a plain [Text], so it stays selectable and copyable inside a
/// `SelectionArea`.
class InlineCodeChip extends StatelessWidget {
  const InlineCodeChip({
    super.key,
    required this.code,
    required this.textStyle,
    required this.background,
    required this.border,
  });

  final String code;
  final TextStyle textStyle;
  final Color background;
  final Color border;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          border: Border.all(color: border, width: 0.75),
          borderRadius: const BorderRadius.all(Radius.circular(5)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 0.5),
          // Wraps inside the chip only when it is wider than the paragraph.
          child: Text(code, style: textStyle),
        ),
      ),
    );
  }
}
