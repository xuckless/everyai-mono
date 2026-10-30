import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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

/// A syntax-highlighted code block with a language label, a Copy button and
/// horizontal scrolling for long lines.
///
/// Styling comes from [style], or from the enclosing `MarkdownView`'s
/// [MarkdownStyle] when [style] is null.
class CodeBlockView extends StatefulWidget {
  const CodeBlockView({super.key, required this.code, this.language, this.style});

  final String code;
  final String? language;
  final MarkdownStyle? style;

  /// How long the "Copied" confirmation stays visible.
  static const Duration copiedDuration = Duration(seconds: 2);

  @override
  State<CodeBlockView> createState() => _CodeBlockViewState();
}

class _CodeBlockViewState extends State<CodeBlockView> {
  Timer? _resetTimer;
  bool _copied = false;

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
    final radius = Radius.circular(style.codeBlockRadius);
    final labelStyle = style.codeBlock.copyWith(
      fontSize: (style.codeBlock.fontSize ?? 13) * 0.85,
      color: (style.codeBlock.color ?? style.body.color)?.withValues(alpha: 0.7),
    );
    final language = widget.language?.trim();

    final header = SelectionContainer.disabled(
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: style.codeBlockBorder)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  language == null || language.isEmpty ? 'text' : language,
                  style: labelStyle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _CopyButton(copied: _copied, style: labelStyle, onPressed: _copy),
            ],
          ),
        ),
      ),
    );

    final body = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(12),
      child: Text.rich(_highlighted(style), softWrap: false),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: style.codeBlockBackground,
        border: Border.all(color: style.codeBlockBorder),
        borderRadius: BorderRadius.all(radius),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.all(radius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[header, body],
        ),
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.copied, required this.style, required this.onPressed});

  final bool copied;
  final TextStyle style;
  final VoidCallback onPressed;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final label = widget.copied ? 'Copied' : 'Copy';
    final color = widget.style.color;
    return Semantics(
      button: true,
      label: widget.copied ? 'Copied' : 'Copy code',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _hovered ? color?.withValues(alpha: 0.12) : null,
              borderRadius: const BorderRadius.all(Radius.circular(4)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(label, style: widget.style),
            ),
          ),
        ),
      ),
    );
  }
}
