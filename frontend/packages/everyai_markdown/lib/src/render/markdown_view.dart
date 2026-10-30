import 'package:flutter/widgets.dart';

import '../code/code_block_view.dart';
import '../parser/document.dart';
import '../style.dart';
import 'block_builder.dart';
import 'math.dart';

/// Renders GitHub-flavored Markdown (plus math) with plain [Text.rich]
/// widgets, so it works inside an app-level `SelectionArea`.
///
/// Parsing is memoized: the document is re-parsed only when [data] changes.
/// While [streaming] is true and [data] grows by appending, only the last
/// top-level block is re-parsed (see [MarkdownDocument.appendParse]) and the
/// widgets of all earlier blocks are reused.
///
/// The view is not scrollable and expects a bounded width.
class MarkdownView extends StatefulWidget {
  const MarkdownView({
    super.key,
    required this.data,
    required this.style,
    this.streaming = false,
    this.mathBuilder,
    this.codeBlockBuilder,
    this.onTapLink,
    this.selectable = true,
    this.preserveSoftLineBreaks = false,
  });

  /// The Markdown source.
  final String data;

  final MarkdownStyle style;

  /// Whether [data] is still being streamed. Enables incremental parsing and
  /// tolerant rendering of unclosed fences and `$$` blocks.
  final bool streaming;

  /// Renders TeX. Defaults to [defaultMathBuilder] (flutter_math_fork).
  ///
  /// Prefer a stable function (top-level or static) so unchanged blocks can
  /// skip rebuilding.
  final MathBuilder? mathBuilder;

  /// Renders code blocks. Defaults to [defaultCodeBlockBuilder], i.e.
  /// [CodeBlockView]. Prefer a stable function, as for [mathBuilder].
  final CodeBlockBuilder? codeBlockBuilder;

  /// Called with the raw `href` when a link is tapped.
  final void Function(String href)? onTapLink;

  /// Whether the text participates in an enclosing `SelectionArea`.
  final bool selectable;

  /// Render soft line breaks (a single newline inside a paragraph) as line
  /// breaks rather than spaces. CommonMark renders them as spaces.
  final bool preserveSoftLineBreaks;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  late MarkdownDocument _document;

  @override
  void initState() {
    super.initState();
    _document = MarkdownDocument.parse(widget.data);
  }

  @override
  void didUpdateWidget(MarkdownView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data != _document.source) {
      _document = widget.streaming
          ? MarkdownDocument.appendParse(_document, widget.data)
          : MarkdownDocument.parse(widget.data);
    } else if (!widget.streaming && _document.isIncremental) {
      // Streaming finished: one full parse resolves references that point
      // forward across blocks (link definitions, footnotes).
      _document = MarkdownDocument.parse(widget.data);
    }
  }

  void _handleTapLink(String href) => widget.onTapLink?.call(href);

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final config = RenderConfig(
      style: style,
      mathBuilder: widget.mathBuilder ?? defaultMathBuilder,
      codeBlockBuilder: widget.codeBlockBuilder ?? defaultCodeBlockBuilder,
      linksEnabled: widget.onTapLink != null,
      preserveSoftBreaks: widget.preserveSoftLineBreaks,
    );

    final children = <Widget>[
      for (var i = 0; i < _document.blocks.length; i++)
        if (_hasVisibleContent(_document.blocks[i]))
          _BlockView(
            key: ValueKey<int>(_document.blocks[i].start),
            block: _document.blocks[i],
            config: config,
            onTapLink: _handleTapLink,
          ),
      if (_document.footnotes.isNotEmpty)
        _FootnotesView(document: _document, config: config, onTapLink: _handleTapLink),
    ];

    Widget result = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: style.blockSpacing,
      children: children,
    );
    result = DefaultSelectionStyle.merge(
      selectionColor: style.selection,
      child: DefaultTextStyle.merge(style: style.body, child: result),
    );
    if (!widget.selectable) {
      result = SelectionContainer.disabled(child: result);
    }
    return MarkdownStyleScope(style: style, child: result);
  }

  static bool _hasVisibleContent(MarkdownBlock block) =>
      block.nodes.any((n) => !MarkdownDocument.isFootnoteDefinition(n));
}

/// Renders one [MarkdownBlock], caching the built subtree while the block
/// object and render configuration stay the same. During streaming this makes
/// every block but the last one free to rebuild.
class _BlockView extends StatefulWidget {
  const _BlockView({super.key, required this.block, required this.config, required this.onTapLink});

  final MarkdownBlock block;
  final RenderConfig config;
  final ValueChanged<String> onTapLink;

  @override
  State<_BlockView> createState() => _BlockViewState();
}

class _BlockViewState extends State<_BlockView> {
  Widget? _cached;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cached = null;
  }

  @override
  void didUpdateWidget(_BlockView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.block, widget.block) || oldWidget.config != widget.config) {
      _cached = null;
    }
  }

  void _handleTapLink(String href) => widget.onTapLink(href);

  @override
  Widget build(BuildContext context) {
    return _cached ??= BlockBuilder(
      context: context,
      config: widget.config,
      onTapLink: _handleTapLink,
      openCodeBlock: widget.block.isOpen ? BlockBuilder.lastCodeBlock(widget.block.nodes) : null,
    ).build(widget.block.nodes);
  }
}

class _FootnotesView extends StatelessWidget {
  const _FootnotesView({required this.document, required this.config, required this.onTapLink});

  final MarkdownDocument document;
  final RenderConfig config;
  final ValueChanged<String> onTapLink;

  @override
  Widget build(BuildContext context) {
    return BlockBuilder(context: context, config: config, onTapLink: onTapLink).buildFootnotes(document.footnotes);
  }
}
