import 'package:flutter/widgets.dart';

import '../style.dart';

/// A Markdown image. Remote (http/https) images are not fetched on their own:
/// model output can carry injected text, and an image URL with data in its
/// query would send that data out the moment it renders. They show the alt
/// text and host, and load only when the user taps. `data:` images render at
/// once; anything else shows the alt text.
class MarkdownImage extends StatefulWidget {
  const MarkdownImage({super.key, required this.src, required this.alt, required this.style});

  final String src;
  final String alt;
  final MarkdownStyle style;

  static const double maxHeight = 400;

  /// The image's host when [src] is an http(s) URL, else null.
  static String? remoteHost(String src) {
    final uri = Uri.tryParse(src);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) return null;
    return uri.host;
  }

  /// The bytes of a `data:image/...` URL, else null.
  static UriData? inlineData(String src) {
    if (!src.startsWith('data:image/')) return null;
    try {
      return UriData.parse(src);
    } on FormatException {
      return null;
    }
  }

  @override
  State<MarkdownImage> createState() => _MarkdownImageState();
}

class _MarkdownImageState extends State<MarkdownImage> {
  bool _load = false;

  @override
  void didUpdateWidget(MarkdownImage old) {
    super.didUpdateWidget(old);
    if (old.src != widget.src) _load = false;
  }

  Widget _box(String text, {String? detail}) {
    final style = widget.style;
    final small = style.body.copyWith(fontSize: (style.body.fontSize ?? 14) * 0.9, color: style.blockquote.color);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: style.codeBlockBackground,
        border: Border.all(color: style.codeBlockBorder),
        borderRadius: BorderRadius.circular(style.codeBlockRadius / 2),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text.rich(
          TextSpan(
            text: text,
            style: small,
            children: [
              if (detail != null)
                TextSpan(
                  text: '  $detail',
                  style: small.copyWith(color: style.link.color),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder() => _box(widget.alt.isEmpty ? 'Image' : widget.alt);

  Widget _framed(Widget image) => Semantics(
    image: true,
    label: widget.alt,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: MarkdownImage.maxHeight),
      child: image,
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (MarkdownImage.inlineData(widget.src) case final data?) {
      return _framed(
        Image.memory(
          data.contentAsBytes(),
          fit: BoxFit.contain,
          excludeFromSemantics: true,
          errorBuilder: (context, error, stackTrace) => _placeholder(),
        ),
      );
    }
    final host = MarkdownImage.remoteHost(widget.src);
    if (host == null) return _placeholder();
    if (!_load) {
      return Semantics(
        button: true,
        label: 'Load image from $host',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _load = true),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: _box(widget.alt.isEmpty ? 'Image' : widget.alt, detail: 'Load from $host'),
          ),
        ),
      );
    }
    return _framed(
      Image.network(
        widget.src,
        fit: BoxFit.contain,
        excludeFromSemantics: true,
        errorBuilder: (context, error, stackTrace) => _placeholder(),
      ),
    );
  }
}
