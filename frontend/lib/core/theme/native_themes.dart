import 'package:cupertino_ui/cupertino_ui.dart' as c;
import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart' as mac;
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../platform/platform_kind.dart';
import 'every_theme.dart';

/// Material 3 Expressive (Android, web) and GNOME/Adwaita (Linux) both build on
/// material_ui; they differ in shape, density, elevation and header style.
m.ThemeData materialTheme(Brightness brightness, {required bool adwaita}) {
  final tokens = EveryTheme.resolve(adwaita ? DesignLanguage.adwaita : DesignLanguage.material, brightness);
  final scheme =
      m.ColorScheme.fromSeed(
        seedColor: EveryPalette.primary,
        brightness: brightness,
        dynamicSchemeVariant: adwaita ? m.DynamicSchemeVariant.neutral : m.DynamicSchemeVariant.expressive,
      ).copyWith(
        surface: tokens.background,
        surfaceContainerLowest: tokens.background,
        surfaceContainerLow: tokens.surface,
        surfaceContainer: tokens.surface,
        surfaceContainerHigh: tokens.surfaceRaised,
        primary: tokens.accent,
        onPrimary: tokens.isDark ? EveryPalette.violet950 : tokens.onPrimary,
        secondary: EveryPalette.secondary,
        error: tokens.danger,
      );

  final radius = BorderRadius.circular(tokens.radius);
  // Expressive buttons are fully rounded "pill" shapes that square off when pressed;
  // Adwaita buttons are 6px-rounded and flat.
  final buttonShape = adwaita
      ? m.RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))
      : const m.StadiumBorder();

  return m.ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: tokens.background,
    visualDensity: adwaita ? m.VisualDensity.compact : m.VisualDensity.standard,
    splashFactory: adwaita ? m.NoSplash.splashFactory : m.InkSparkle.splashFactory,
    appBarTheme: m.AppBarTheme(
      backgroundColor: adwaita ? tokens.surface : tokens.background,
      foregroundColor: tokens.text,
      elevation: 0,
      scrolledUnderElevation: adwaita ? 0 : 2,
      centerTitle: adwaita,
      toolbarHeight: adwaita ? 47 : 64,
      shape: adwaita ? m.Border(bottom: BorderSide(color: tokens.border)) : null,
      titleTextStyle: TextStyle(
        color: tokens.text,
        fontSize: adwaita ? 15 : 22,
        fontWeight: adwaita ? FontWeight.w700 : FontWeight.w500,
      ),
    ),
    // Filled buttons are violet 500 with white text in both themes.
    filledButtonTheme: m.FilledButtonThemeData(
      style: m.FilledButton.styleFrom(
        shape: buttonShape,
        backgroundColor: tokens.primary,
        foregroundColor: tokens.onPrimary,
      ),
    ),
    textButtonTheme: m.TextButtonThemeData(style: m.TextButton.styleFrom(shape: buttonShape)),
    outlinedButtonTheme: m.OutlinedButtonThemeData(style: m.OutlinedButton.styleFrom(shape: buttonShape)),
    iconButtonTheme: m.IconButtonThemeData(
      style: m.IconButton.styleFrom(
        shape: adwaita ? m.RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)) : const m.CircleBorder(),
      ),
    ),
    cardTheme: m.CardThemeData(
      elevation: 0,
      color: tokens.surface,
      shape: m.RoundedRectangleBorder(
        borderRadius: radius,
        side: adwaita ? BorderSide(color: tokens.border) : BorderSide.none,
      ),
    ),
    dialogTheme: m.DialogThemeData(
      backgroundColor: tokens.surface,
      shape: m.RoundedRectangleBorder(borderRadius: BorderRadius.circular(adwaita ? 12 : 28)),
    ),
    drawerTheme: m.DrawerThemeData(backgroundColor: tokens.surface),
    listTileTheme: m.ListTileThemeData(
      selectedTileColor: tokens.accent.withValues(alpha: 0.14),
      selectedColor: tokens.text,
      iconColor: tokens.textMuted,
    ),
    dividerTheme: m.DividerThemeData(color: tokens.border, space: 1, thickness: 1),
    tooltipTheme: m.TooltipThemeData(waitDuration: const Duration(milliseconds: 500)),
    pageTransitionsTheme: const m.PageTransitionsTheme(
      builders: {TargetPlatform.android: m.PredictiveBackPageTransitionsBuilder()},
    ),
    extensions: const [],
  );
}

/// Shape for model avatars on Material: the Expressive "cookie" polygon.
final expressiveAvatarShape = MaterialShapes.cookie9Sided;

c.CupertinoThemeData cupertinoTheme(Brightness brightness) {
  final tokens = EveryTheme.resolve(DesignLanguage.cupertino, brightness);
  return c.CupertinoThemeData(
    brightness: brightness,
    primaryColor: tokens.accent,
    scaffoldBackgroundColor: tokens.background,
    barBackgroundColor: tokens.surface.withValues(alpha: 0.6),
    // Cupertino's defaults are phone sizes (17pt body). On a desktop window
    // they read heavy, so use desktop sizes there.
    textTheme: Host.isDesktop ? _desktopCupertinoText : null,
  );
}

final _desktopCupertinoText = () {
  const base = c.CupertinoTextThemeData();
  TextStyle size(TextStyle s, double px, [FontWeight? w]) =>
      s.copyWith(fontSize: px, letterSpacing: -0.1, fontWeight: w ?? s.fontWeight);
  return c.CupertinoTextThemeData(
    textStyle: size(base.textStyle, 14),
    actionTextStyle: size(base.actionTextStyle, 14),
    actionSmallTextStyle: size(base.actionSmallTextStyle, 13),
    tabLabelTextStyle: size(base.tabLabelTextStyle, 11),
    navTitleTextStyle: size(base.navTitleTextStyle, 14, FontWeight.w600),
    navLargeTitleTextStyle: size(base.navLargeTitleTextStyle, 26, FontWeight.w600),
    navActionTextStyle: size(base.navActionTextStyle, 14),
    pickerTextStyle: size(base.pickerTextStyle, 15),
    dateTimePickerTextStyle: size(base.dateTimePickerTextStyle, 15),
  );
}();

/// macos_ui only takes system accent colors; brand violet reaches its push
/// buttons through AdaptiveButton.
mac.MacosThemeData macosTheme(Brightness brightness) {
  final tokens = EveryTheme.resolve(DesignLanguage.macos, brightness);
  final base = brightness == Brightness.dark
      ? mac.MacosThemeData.dark(accentColor: mac.AccentColor.purple)
      : mac.MacosThemeData.light(accentColor: mac.AccentColor.purple);
  return base.copyWith(canvasColor: tokens.background, dividerColor: tokens.border);
}

f.FluentThemeData fluentTheme(Brightness brightness) {
  final accent = f.AccentColor.swatch(const {
    'darkest': EveryPalette.violet900,
    'darker': EveryPalette.violet800,
    'dark': EveryPalette.violet700,
    'normal': EveryPalette.violet500,
    'light': EveryPalette.violet400,
    'lighter': EveryPalette.violet300,
    'lightest': EveryPalette.violet200,
  });
  return f.FluentThemeData(
    brightness: brightness,
    accentColor: accent,
    visualDensity: f.VisualDensity.standard,
    fontFamily: 'Segoe UI Variable',
  );
}
