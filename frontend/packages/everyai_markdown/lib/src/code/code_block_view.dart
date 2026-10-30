import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../render/scroll.dart';
import '../style.dart';
import 'highlighter.dart';

/// Builds the widget for a fenced or indented code block.
///
/// [language] is the fence info string's first word (e.g. `dart`, `typst`),
/// or `null` when absent.
typedef CodeBlockBuilder = Widget Function(BuildContext context, String code, String? language);

/// The default [CodeBlockBuilder]: a [CodeBlockView].
Widget defaultCodeBlockBuilder(BuildContext context, String code, String? language) =>
    CodeBlockView(code: code, language: language);

/// A syntax-highlighted code block in the style of chat apps: a header bar
/// with the language on the left and line-wrap / Copy buttons on the right,
/// and a body that scrolls horizontally unless line wrapping is on.
///
/// Styling comes from [style], or from the enclosing `MarkdownView`'s
/// [MarkdownStyle] when [style] is null.
class CodeBlockView extends StatefulWidget {
  const CodeBlockView({
    super.key,
    required this.code,
    this.language,
    this.style,
    this.initiallyWrapped = false,
    this.showWrapToggle = true,
  });

  final String code;
  final String? language;
  final MarkdownStyle? style;

  /// Whether long lines wrap when the block first appears.
  final bool initiallyWrapped;

  /// Whether the header shows the line-wrap toggle.
  final bool showWrapToggle;

  /// How long the "Copied" confirmation stays visible.
  static const Duration copiedDuration = Duration(seconds: 2);

  @override
  State<CodeBlockView> createState() => _CodeBlockViewState();
}

class _CodeBlockViewState extends State<CodeBlockView> {
  Timer? _resetTimer;
  bool _copied = false;
  late bool _wrap = widget.initiallyWrapped;

  // Memoized highlight result.
  TextSpan? _span;
  String? _spanCode;
  String? _spanLanguage;
  MarkdownStyle? _spanStyle;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(CodeBlockView.copiedDuration, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  TextSpan _highlighted(MarkdownStyle style) {
    if (_span == null || _spanCode != widget.code || _spanLanguage != widget.language || _spanStyle != style) {
      _span = CodeHighlighter.highlight(widget.code, widget.language, base: style.codeBlock, theme: style.syntaxTheme);
      _spanCode = widget.code;
      _spanLanguage = widget.language;
      _spanStyle = style;
    }
    return _span!;
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style ?? MarkdownStyle.of(context);
    final radius = BorderRadius.circular(style.codeBlockRadius);
    final foreground = style.codeBlock.color ?? style.body.color ?? const Color(0xFF888888);
    final muted = foreground.withValues(alpha: 0.72);
    final labelStyle = TextStyle(
      fontFamily: style.body.fontFamily,
      fontFamilyFallback: style.body.fontFamilyFallback,
      fontSize: 12,
      height: 1.2,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.2,
      color: muted,
    );
    final language = widget.language?.trim();

    final header = SelectionContainer.disabled(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: style.codeHeaderBackground,
          border: Border(bottom: BorderSide(color: style.codeBlockBorder, width: 0.5)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
          child: Row(
            spacing: 2,
            children: <Widget>[
              Expanded(
                child: Text(
                  language == null || language.isEmpty ? 'text' : language,
                  style: labelStyle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.showWrapToggle)
                _HeaderButton(
                  semanticsLabel: _wrap ? 'Disable line wrap' : 'Wrap lines',
                  toggled: _wrap,
                  color: muted,
                  activeColor: foreground,
                  onPressed: () => setState(() => _wrap = !_wrap),
                  icon: _WrapIcon(color: _wrap ? foreground : muted),
                ),
              _HeaderButton(
                semanticsLabel: _copied ? 'Copied' : 'Copy code',
                color: muted,
                activeColor: foreground,
                onPressed: _copy,
                icon: _copied ? _CheckIcon(color: muted) : _CopyIcon(color: muted),
                label: Text(_copied ? 'Copied' : 'Copy', style: labelStyle),
              ),
            ],
          ),
        ),
      ),
    );

    final code = Text.rich(_highlighted(style), softWrap: _wrap);
    const padding = EdgeInsets.fromLTRB(16, 12, 16, 14);
    final body = _wrap
        ? Padding(padding: padding, child: code)
        : HorizontalScroller(padding: padding, thumbColor: foreground.withValues(alpha: 0.25), child: code);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: style.codeBlockBackground,
        border: Border.all(color: style.codeBlockBorder),
        borderRadius: radius,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[header, body],
        ),
      ),
    );
  }
}

/// A small hoverable header button: an icon plus an optional label.
class _HeaderButton extends StatefulWidget {
  const _HeaderButton({
    required this.semanticsLabel,
    required this.color,
    required this.activeColor,
    required this.onPressed,
    required this.icon,
    this.label,
    this.toggled,
  });

  final String semanticsLabel;
  final Color color;
  final Color activeColor;
  final VoidCallback onPressed;
  final Widget icon;
  final Widget? label;
  final bool? toggled;

  @override
  State<_HeaderButton> createState() => _HeaderButtonState();
}

class _HeaderButtonState extends State<_HeaderButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = _hovered || (widget.toggled ?? false);
    final label = widget.label;
    return Semantics(
      button: true,
      toggled: widget.toggled,
      label: widget.semanticsLabel,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 28,
            constraints: const BoxConstraints(minWidth: 28),
            padding: EdgeInsets.symmetric(horizontal: label == null ? 7 : 8),
            decoration: BoxDecoration(
              color: highlighted ? widget.activeColor.withValues(alpha: _hovered ? 0.12 : 0.08) : null,
              borderRadius: const BorderRadius.all(Radius.circular(6)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, spacing: 5, children: <Widget>[widget.icon, ?label]),
          ),
        ),
      ),
    );
  }
}

abstract class _StrokeIcon extends StatelessWidget {
  const _StrokeIcon({required this.color});

  final Color color;

  /// Draws the icon on a 16x16 grid.
  void paintIcon(Canvas canvas, Paint paint);

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: 14, child: CustomPaint(painter: _IconPainter(this, color)));
}

class _IconPainter extends CustomPainter {
  _IconPainter(this.icon, this.color);

  final _StrokeIcon icon;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 16, size.height / 16);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    icon.paintIcon(canvas, paint);
  }

  @override
  bool shouldRepaint(_IconPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.icon.runtimeType != icon.runtimeType;
}

class _CopyIcon extends _StrokeIcon {
  const _CopyIcon({required super.color});

  @override
  void paintIcon(Canvas canvas, Paint paint) {
    canvas.drawRRect(RRect.fromLTRBR(5.5, 5.5, 14, 14, const Radius.circular(2)), paint);
    canvas.drawPath(
      Path()
        ..moveTo(10.5, 4)
        ..arcToPoint(const Offset(8.5, 2), radius: const Radius.circular(2), clockwise: false)
        ..lineTo(4, 2)
        ..arcToPoint(const Offset(2, 4), radius: const Radius.circular(2), clockwise: false)
        ..lineTo(2, 8.5)
        ..arcToPoint(const Offset(4, 10.5), radius: const Radius.circular(2), clockwise: false),
      paint,
    );
  }
}

class _CheckIcon extends _StrokeIcon {
  const _CheckIcon({required super.color});

  @override
  void paintIcon(Canvas canvas, Paint paint) {
    canvas.drawPath(
      Path()
        ..moveTo(2.5, 8.5)
        ..lineTo(6.2, 12)
        ..lineTo(13.5, 4),
      paint..strokeWidth = 1.7,
    );
  }
}

class _WrapIcon extends _StrokeIcon {
  const _WrapIcon({required super.color});

  @override
  void paintIcon(Canvas canvas, Paint paint) {
    canvas
      ..drawLine(const Offset(2, 3.5), const Offset(14, 3.5), paint)
      ..drawPath(
        Path()
          ..moveTo(2, 8)
          ..lineTo(11, 8)
          ..cubicTo(14.7, 8, 14.7, 12.5, 11, 12.5)
          ..lineTo(8, 12.5)
          ..moveTo(9.7, 10.8)
          ..lineTo(8, 12.5)
          ..lineTo(9.7, 14.2),
        paint,
      )
      ..drawLine(const Offset(2, 12.5), const Offset(5, 12.5), paint);
  }
}
