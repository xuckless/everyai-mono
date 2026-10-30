/// Streaming-friendly GitHub-flavored Markdown renderer for EveryAI, with
/// math and code highlighting. Design-system neutral: depends only on
/// `package:flutter/widgets.dart`.
library;

export 'src/code/highlighter.dart' show CodeHighlighter;
export 'src/code/language_for_path.dart' show languageForPath;
export 'src/code/code_block_view.dart' show CodeBlockBuilder, CodeBlockView, defaultCodeBlockBuilder;
export 'src/parser/document.dart' show MarkdownBlock, MarkdownDocument, MarkdownFootnote;
export 'src/render/chips.dart' show CitationBuilder, CitationChip, defaultCitationBuilder;
export 'src/render/markdown_view.dart' show MarkdownView;
export 'src/render/math.dart' show MathBuilder, defaultMathBuilder;
export 'src/style.dart' show MarkdownStyle;
export 'src/code/syntax_themes.dart' show githubLightSyntaxTheme, oneDarkSyntaxTheme;
