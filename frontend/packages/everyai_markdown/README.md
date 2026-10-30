# everyai_markdown

GitHub-flavored Markdown renderer for EveryAI, built for streaming LLM output.

- Depends only on `package:flutter/widgets.dart` (plus `services`/`rendering`):
  no Material or Cupertino. All visuals come from a `MarkdownStyle`.
- Renders plain `Text.rich` widgets, so text is selectable by an app-level
  `SelectionArea`.
- Supports GFM (tables, task lists, strikethrough, autolinks, footnotes,
  alerts), images, and math (`$…$`, `\(…\)`, `$$…$$`, `\[…\]`, and fenced
  `math`/`latex`/`tex` blocks).
- Includes code blocks with syntax highlighting, a language label and a Copy
  button.
- Streaming: while `streaming: true`, appended text re-parses only the last
  top-level block. Unclosed fences render as code in progress, and an
  unclosed `$$` renders as plain text until it is closed.

## Usage

```dart
import 'package:everyai_markdown/everyai_markdown.dart';

MarkdownView(
  data: message.text,
  streaming: message.isStreaming,
  style: MarkdownStyle.fallback(Brightness.dark).copyWith(
    body: const TextStyle(fontSize: 16, height: 1.5, color: Color(0xFFECECEC)),
  ),
  onTapLink: (href) => launchUrlString(href),
);
```

Custom builders (for example a Typst-based math renderer) plug in through
`mathBuilder` and `codeBlockBuilder`. Inside a builder,
`MarkdownStyle.of(context)` returns the active style:

```dart
MarkdownView(
  data: text,
  style: style,
  mathBuilder: (context, tex, {required display}) =>
      MyTypstMath(tex, display: display),
  codeBlockBuilder: (context, code, language) => language == 'typst'
      ? MyTypstPreview(code)
      : CodeBlockView(code: code, language: language),
);
```

Citation markers from search-backed models (`[1]`, `[1][3]`) render as small
accent chips. A marker is not a citation when it is a link (`[1](url)`, a
defined `[1]: url` reference), or when it sits inside a link or code. Handle
taps with `onTapCitation: (index) => ...`, and replace the chip with
`citationBuilder`.

Pass stable functions (top-level or static) as builders. Unchanged blocks
then skip rebuilding.

`MarkdownDocument.parse` and `MarkdownDocument.appendParse` are public for
callers that want to parse ahead of time or cache documents.
