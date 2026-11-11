import 'package:flutter/widgets.dart';

import '../theme/every_theme.dart';

// Glass surfaces: a translucent fill with a lit top edge over a softly glowing backdrop. No BackdropFilter per card
// (a board holds dozens and each blur pass costs a layer); the backdrop's glow shows through the fill instead.

/// A glass card's decoration: [theme]'s surface at a little transparency, a highlight across its top, a hairline
/// border ([edge] tints it: amber for a warning, red for a failure), and a soft shadow when [hovered].
BoxDecoration glassDecoration(EveryTheme theme, {bool hovered = false, Color? edge, double radius = 16}) {
  final base = theme.surface;
  const lit = Color(0xFFFFFFFF);
  return BoxDecoration(
    borderRadius: BorderRadius.circular(radius),
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color.alphaBlend(lit.withValues(alpha: theme.isDark ? 0.045 : 0.6), base.withValues(alpha: 0.82)),
        base.withValues(alpha: theme.isDark ? 0.72 : 0.9),
      ],
    ),
    border: Border.all(
      color: edge?.withValues(alpha: 0.75) ?? (hovered ? theme.borderStrong : theme.border),
      width: edge == null ? 1 : 1.2,
    ),
    boxShadow: hovered ? theme.shadowSoft : null,
  );
}

/// A quiet backdrop for glass: [theme]'s background with two faint accent glows, one top left and one bottom right.
class GlowBackdrop extends StatelessWidget {
  const GlowBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final a = theme.isDark ? 0.10 : 0.06;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-0.9, -1.1),
          radius: 1.2,
          colors: [
            theme.accent.withValues(alpha: a),
            theme.accent.withValues(alpha: 0),
          ],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(1.1, 1.2),
            radius: 1.1,
            colors: [
              theme.cyan.withValues(alpha: a * 0.7),
              theme.cyan.withValues(alpha: 0),
            ],
          ),
        ),
        child: child,
      ),
    );
  }
}
