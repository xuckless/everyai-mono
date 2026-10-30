import 'package:everyai_markdown/everyai_markdown.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/every_theme.dart';
import '../../artifacts/ui/renderers/svg_view.dart';
import '../../artifacts/ui/renderers/web_view.dart';
import '../domain/message.dart';

/// Markdown for chat content, styled from the app tokens so it matches every
/// design language. The only place the app touches the renderer package.
class ChatMarkdown extends StatelessWidget {
  const ChatMarkdown(this.data, {super.key, this.streaming = false, this.textColor, this.sources = const []});

  final String data;
  final bool streaming;

  /// Sources the `[n]` citations in [data] point at (search modes).
  final List<Source> sources;

  /// Overrides the body color (user bubbles sit on the accent-tinted fill).
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return MarkdownView(
      data: data,
      streaming: streaming,
      style: _styleFor(theme, DefaultTextStyle.of(context).style, textColor),
      codeBlockBuilder: _figures,
      onTapCitation: sources.isEmpty
          ? null
          : (index) {
              if (index >= 1 && index <= sources.length) {
                launchUrl(sources[index - 1].url, mode: LaunchMode.externalApplication);
              }
            },
      onTapLink: (href) {
        final uri = Uri.tryParse(href);
        if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http' || uri.scheme == 'mailto')) {
          launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
    );
  }

  /// ```svg blocks draw as figures and ```mermaid blocks as diagrams, once
  /// complete; anything else (or a block still streaming) is code.
  static Widget _figures(BuildContext context, String text, String? language) {
    switch (language?.toLowerCase()) {
      case 'svg' when text.contains('</svg>'):
        return SvgView(svg: text, maxHeight: 560);
      case 'mermaid' when text.trim().isNotEmpty && inlineWebSupported:
        final dark = EveryTheme.of(context).brightness == Brightness.dark;
        return WebContentView(
          html: mermaidPage(text, dark: dark),
          fallbackSource: text,
          height: 340,
        );
    }
    return defaultCodeBlockBuilder(context, text, language);
  }

  static MarkdownStyle _styleFor(EveryTheme t, TextStyle ambient, Color? textColor) {
    final base = MarkdownStyle.fallback(t.brightness);
    final body = ambient.copyWith(color: textColor ?? t.text, fontSize: 15, height: 1.55);
    TextStyle heading(double size) => body.copyWith(fontSize: size, fontWeight: FontWeight.w700, height: 1.3);
    final mono = body.copyWith(fontFamily: 'SourceCodePro', fontSize: 13.5, height: 1.5);
    return base.copyWith(
      body: body,
      h1: heading(24),
      h2: heading(20),
      h3: heading(17),
      h4: heading(15),
      h5: heading(14),
      h6: heading(13),
      // Text color comes from the package's chip palette (warm on dark, plum on light).
      inlineCode: base.inlineCode.copyWith(fontFamily: 'SourceCodePro', fontSize: 13),
      codeBlock: mono,
      blockquote: body.copyWith(color: t.textMuted),
      // Underline on hover only (handled by the renderer).
      link: body.copyWith(color: t.accent, decorationColor: t.accent),
      codeBlockBackground: t.codeBackground,
      citationBackground: t.accent.withValues(alpha: 0.18),
      citationText: t.text,
      codeBlockBorder: t.border,
      blockquoteBar: t.accent.withValues(alpha: 0.6),
      tableBorder: t.border,
      ruleColor: t.border,
      codeBlockRadius: t.radius,
    );
  }
}
