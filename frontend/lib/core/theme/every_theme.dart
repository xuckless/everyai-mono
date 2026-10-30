import 'package:flutter/widgets.dart';

import '../platform/platform_kind.dart';

/// Brand palette. The original EveryAI navy and purple, with the accent lifted so
/// it reaches WCAG AA contrast on both light and dark surfaces.
abstract final class Brand {
  static const navy = Color(0xFF181C26);
  static const slate = Color(0xFF2A3041);
  static const plum = Color(0xFF2F1555);

  /// Interactive accent derived from [plum].
  static const violet = Color(0xFF6E4BD8);
  static const violetLight = Color(0xFFB9A4FF);
}

/// Design-language-neutral tokens for app content: chat bubbles, code, markdown,
/// empty states. Native chrome (bars, buttons, menus) comes from each design system.
@immutable
final class EveryTheme {
  const EveryTheme({
    required this.design,
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.border,
    required this.text,
    required this.textMuted,
    required this.accent,
    required this.onAccent,
    required this.userBubble,
    required this.onUserBubble,
    required this.danger,
    required this.codeBackground,
    required this.radius,
    required this.bubbleRadius,
  });

  factory EveryTheme.resolve(DesignLanguage design, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final radius = switch (design) {
      DesignLanguage.cupertino => 14.0,
      DesignLanguage.macos => 8.0,
      DesignLanguage.material => 16.0,
      DesignLanguage.fluent => 6.0,
      DesignLanguage.adwaita => 12.0,
    };
    return EveryTheme(
      design: design,
      brightness: brightness,
      background: dark ? Brand.navy : const Color(0xFFF7F6FB),
      surface: dark ? const Color(0xFF1F2430) : const Color(0xFFFFFFFF),
      surfaceRaised: dark ? Brand.slate : const Color(0xFFEFEDF6),
      border: dark ? const Color(0x22FFFFFF) : const Color(0x1A1B1530),
      text: dark ? const Color(0xFFECEAF4) : const Color(0xFF1B1530),
      textMuted: dark ? const Color(0xFF9C99AD) : const Color(0xFF66617A),
      accent: dark ? Brand.violetLight : Brand.violet,
      onAccent: dark ? Brand.plum : const Color(0xFFFFFFFF),
      userBubble: dark ? const Color(0xFF3A2A6E) : const Color(0xFFE6DEFF),
      onUserBubble: dark ? const Color(0xFFF1ECFF) : const Color(0xFF21114A),
      danger: dark ? const Color(0xFFFF8A80) : const Color(0xFFC62828),
      codeBackground: dark ? const Color(0xFF12151C) : const Color(0xFFF2F1F7),
      radius: radius,
      bubbleRadius: design == DesignLanguage.cupertino || design == DesignLanguage.material ? 20 : radius + 6,
    );
  }

  final DesignLanguage design;
  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color surfaceRaised;
  final Color border;
  final Color text;
  final Color textMuted;
  final Color accent;
  final Color onAccent;
  final Color userBubble;
  final Color onUserBubble;
  final Color danger;
  final Color codeBackground;
  final double radius;
  final double bubbleRadius;

  bool get isDark => brightness == Brightness.dark;

  static EveryTheme of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<EveryThemeScope>()!.theme;
}

class EveryThemeScope extends InheritedWidget {
  const EveryThemeScope({super.key, required this.theme, required super.child});

  final EveryTheme theme;

  @override
  bool updateShouldNotify(EveryThemeScope oldWidget) =>
      theme.design != oldWidget.theme.design || theme.brightness != oldWidget.theme.brightness;
}

/// Window-size classes, following Material's adaptive breakpoints.
enum WindowSize {
  compact,
  medium,
  expanded;

  static WindowSize of(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return width < 600
        ? compact
        : width < 1024
        ? medium
        : expanded;
  }
}
