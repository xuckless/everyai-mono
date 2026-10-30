import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../core/theme/every_theme.dart';

/// Removes what an inline illustration must not have: scripts, event
/// handlers, foreign HTML and references to outside resources.
String sanitizeSvg(String svg) => svg
    .replaceAll(RegExp(r'<script[\s\S]*?</script\s*>', caseSensitive: false), '')
    .replaceAll(RegExp(r'<foreignObject[\s\S]*?</foreignObject\s*>', caseSensitive: false), '')
    .replaceAll(RegExp(r'''\son\w+\s*=\s*("[^"]*"|'[^']*')''', caseSensitive: false), '')
    .replaceAll(
      RegExp(r'''(xlink:)?href\s*=\s*("|')\s*(https?:|javascript:|data:text)[^"']*\2''', caseSensitive: false),
      '',
    );

/// `render_svg` and SVG artifacts.
class SvgView extends StatelessWidget {
  const SvgView({super.key, required this.svg, this.maxHeight = 420});

  final String svg;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          // Model SVGs usually assume a light page.
          color: const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(theme.radius),
          border: Border.all(color: theme.border),
        ),
        child: SvgPicture.string(
          sanitizeSvg(svg),
          fit: BoxFit.contain,
          errorBuilder: (context, error, _) =>
              Text('This illustration could not be drawn.', style: TextStyle(color: theme.textMuted)),
        ),
      ),
    );
  }
}
