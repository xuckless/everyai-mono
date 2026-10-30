import 'package:everyai_markdown/everyai_markdown.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/every_theme.dart';

/// Markdown for chat content, styled from the app tokens so it matches every
/// design language. The only place the app touches the renderer package.
class ChatMarkdown extends StatelessWidget {
  const ChatMarkdown(this.data, {super.key, this.streaming = false, this.textColor});

  final String data;
  final bool streaming;

  /// Overrides the body color (user bubbles sit on the accent-tinted fill).
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return MarkdownView(
      data: data,
      streaming: streaming,
      style: _styleFor(theme, DefaultTextStyle.of(context).style, textColor),
      onTapLink: (href) {
        final uri = Uri.tryParse(href);
        if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http' || uri.scheme == 'mailto')) {
          launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
    );
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
      inlineCode: mono.copyWith(backgroundColor: t.codeBackground, fontSize: 13.5),
      codeBlock: mono,
      blockquote: body.copyWith(color: t.textMuted),
      link: body.copyWith(color: t.accent, decoration: TextDecoration.underline, decorationColor: t.accent),
      codeBlockBackground: t.codeBackground,
      codeBlockBorder: t.border,
      blockquoteBar: t.accent.withValues(alpha: 0.6),
      tableBorder: t.border,
      ruleColor: t.border,
      codeBlockRadius: t.radius,
    );
  }
}
