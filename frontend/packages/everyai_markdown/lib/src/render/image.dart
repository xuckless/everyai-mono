import 'package:flutter/widgets.dart';

import '../style.dart';

/// A Markdown image: [Image.network] for http(s) URLs, otherwise (or on load
/// failure) a placeholder box showing the alt text.
class MarkdownImage extends StatelessWidget {
  const MarkdownImage({super.key, required this.src, required this.alt, required this.style});

  final String src;
  final String alt;
  final MarkdownStyle style;

  static const double maxHeight = 400;

  bool get _isNetwork {
    final uri = Uri.tryParse(src);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
  }

  Widget _placeholder() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: style.codeBlockBackground,
        border: Border.all(color: style.codeBlockBorder),
        borderRadius: BorderRadius.circular(style.codeBlockRadius / 2),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          alt.isEmpty ? 'Image' : alt,
          style: style.body.copyWith(fontSize: (style.body.fontSize ?? 14) * 0.9, color: style.blockquote.color),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isNetwork) return _placeholder();
    return Semantics(
      image: true,
      label: alt,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: maxHeight),
        child: Image.network(
          src,
          fit: BoxFit.contain,
          excludeFromSemantics: true,
          errorBuilder: (context, error, stackTrace) => _placeholder(),
        ),
      ),
    );
  }
}
