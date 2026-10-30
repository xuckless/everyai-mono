import 'package:flutter/widgets.dart';

import '../platform/platform_kind.dart';
import 'every_type.dart';
import 'everyai_brand.dart';

export 'every_type.dart';
export 'everyai_brand.dart';

/// Design-language-neutral tokens for app content: chat bubbles, code, markdown,
/// empty states. Native chrome (bars, buttons, menus) comes from each design
/// system. Colors are the brand kit's roles (`everyai_brand.dart`).
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
    required this.primary,
    required this.onPrimary,
    required this.link,
    required this.userBubble,
    required this.onUserBubble,
    required this.success,
    required this.warning,
    required this.danger,
    required this.codeBackground,
    required this.radius,
    required this.bubbleRadius,
    required this.type,
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
    final type = EveryType.resolve();
    return dark
        ? EveryTheme(
            design: design,
            brightness: brightness,
            background: EveryRolesDark.background,
            surface: EveryRolesDark.surface,
            surfaceRaised: EveryRolesDark.surfaceRaised,
            border: EveryRolesDark.border,
            text: EveryRolesDark.text,
            textMuted: EveryRolesDark.textMuted,
            accent: EveryRolesDark.accent,
            primary: EveryRolesDark.primary,
            onPrimary: EveryRolesDark.onPrimary,
            link: EveryRolesDark.link,
            userBubble: EveryRolesDark.userBubble,
            onUserBubble: EveryRolesDark.onUserBubble,
            success: EveryRolesDark.success,
            warning: EveryRolesDark.warning,
            danger: EveryRolesDark.danger,
            codeBackground: EveryRolesDark.codeBackground,
            radius: radius,
            bubbleRadius: 18,
            type: type,
          )
        : EveryTheme(
            design: design,
            brightness: brightness,
            background: EveryRolesLight.background,
            surface: EveryRolesLight.surface,
            surfaceRaised: EveryRolesLight.surfaceRaised,
            border: EveryRolesLight.border,
            text: EveryRolesLight.text,
            textMuted: EveryRolesLight.textMuted,
            accent: EveryRolesLight.accent,
            primary: EveryRolesLight.primary,
            onPrimary: EveryRolesLight.onPrimary,
            link: EveryRolesLight.link,
            userBubble: EveryRolesLight.userBubble,
            onUserBubble: EveryRolesLight.onUserBubble,
            success: EveryRolesLight.success,
            warning: EveryRolesLight.warning,
            danger: EveryRolesLight.danger,
            codeBackground: EveryRolesLight.codeBackground,
            radius: radius,
            bubbleRadius: 18,
            type: type,
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

  /// Violet for text, icons, outlines and selection on either surface.
  final Color accent;

  /// Violet 500 for filled controls (send, checkboxes, primary buttons), with
  /// [onPrimary] on top. Same in both themes.
  final Color primary;
  final Color onPrimary;
  final Color link;
  final Color userBubble;
  final Color onUserBubble;
  final Color success;
  final Color warning;
  final Color danger;
  final Color codeBackground;

  /// Native control radius for the design language.
  final double radius;
  final double bubbleRadius;

  /// The app's type scale; see [EveryType].
  final EveryType type;

  /// Brand shapes: cards r20, panels r24, the bubble's tail corner r6.
  static const cardRadius = 20.0;
  static const panelRadius = 24.0;
  static const bubbleTail = 6.0;

  /// A user bubble: [bubbleRadius] all round except the tail corner
  /// (bottom-right, toward the sender).
  BorderRadius get userBubbleShape => BorderRadius.only(
    topLeft: Radius.circular(bubbleRadius),
    topRight: Radius.circular(bubbleRadius),
    bottomLeft: Radius.circular(bubbleRadius),
    bottomRight: const Radius.circular(bubbleTail),
  );

  /// The brand's live-state color: cyan on dark, violet on light (glyph dots,
  /// the mark's dot).
  Color get signal => isDark ? EveryPalette.cyan400 : EveryPalette.violet600;

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
