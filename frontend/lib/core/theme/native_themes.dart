import 'package:cupertino_ui/cupertino_ui.dart' as c;
import 'package:flutter/widgets.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../platform/platform_kind.dart';
import 'every_theme.dart';

/// The Material theme under the app's single root. Material only supplies the
/// plumbing (navigation, text editing, selection, the odd leftover widget), so
/// this maps the kit's tokens onto it and turns its own effects off: no ink
/// splashes, no tinted elevation, Geist everywhere.
m.ThemeData kitMaterialTheme(Brightness brightness, {bool pureBlack = false}) {
  final t = EveryTheme.resolve(DesignLanguage.material, brightness, pureBlack: pureBlack);
  final scheme = m.ColorScheme.fromSeed(seedColor: t.primary, brightness: brightness).copyWith(
    surface: t.surface,
    surfaceContainerLowest: t.background,
    surfaceContainerLow: t.surface,
    surfaceContainer: t.surface,
    surfaceContainerHigh: t.surfaceRaised,
    surfaceContainerHighest: t.overlay,
    primary: t.primary,
    onPrimary: t.onPrimary,
    secondary: t.cyan,
    error: t.danger,
    onSurface: t.text,
    onSurfaceVariant: t.textMuted,
    outline: t.borderStrong,
    outlineVariant: t.border,
  );
  final rounded = m.RoundedRectangleBorder(borderRadius: BorderRadius.circular(9));
  return m.ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: EveryType.family,
    scaffoldBackgroundColor: t.background,
    canvasColor: t.background,
    splashFactory: m.NoSplash.splashFactory,
    highlightColor: const Color(0x00000000),
    hoverColor: t.hover,
    focusColor: t.hover,
    visualDensity: m.VisualDensity.standard,
    textSelectionTheme: m.TextSelectionThemeData(
      cursorColor: t.accent,
      selectionColor: t.primary.withValues(alpha: 0.35),
      selectionHandleColor: t.accent,
    ),
    appBarTheme: m.AppBarTheme(
      backgroundColor: t.surface,
      foregroundColor: t.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: const Color(0x00000000),
      titleTextStyle: t.type.headline.tint(t.text),
    ),
    filledButtonTheme: m.FilledButtonThemeData(
      style: m.FilledButton.styleFrom(shape: rounded, backgroundColor: t.primary, foregroundColor: t.onPrimary),
    ),
    textButtonTheme: m.TextButtonThemeData(
      style: m.TextButton.styleFrom(shape: rounded, foregroundColor: t.text),
    ),
    outlinedButtonTheme: m.OutlinedButtonThemeData(style: m.OutlinedButton.styleFrom(shape: rounded)),
    iconButtonTheme: m.IconButtonThemeData(
      style: m.IconButton.styleFrom(shape: rounded, foregroundColor: t.textMuted),
    ),
    cardTheme: m.CardThemeData(
      elevation: 0,
      color: t.surface,
      shape: m.RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: t.border),
      ),
    ),
    dialogTheme: m.DialogThemeData(
      backgroundColor: t.overlay,
      surfaceTintColor: const Color(0x00000000),
      shape: m.RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: t.borderStrong),
      ),
    ),
    drawerTheme: m.DrawerThemeData(backgroundColor: t.surface, surfaceTintColor: const Color(0x00000000)),
    listTileTheme: m.ListTileThemeData(
      selectedTileColor: t.hover,
      selectedColor: t.text,
      iconColor: t.textMuted,
      shape: rounded,
    ),
    dividerTheme: m.DividerThemeData(color: t.border, space: 1, thickness: 1),
    scrollbarTheme: m.ScrollbarThemeData(
      thumbColor: m.WidgetStatePropertyAll(t.borderStrong),
      radius: const Radius.circular(8),
      thickness: const m.WidgetStatePropertyAll(6),
    ),
    tooltipTheme: m.TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: t.overlay,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: t.borderStrong),
      ),
      textStyle: t.type.caption.tint(t.text),
    ),
    pageTransitionsTheme: const m.PageTransitionsTheme(
      builders: {
        TargetPlatform.android: m.FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: c.CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: m.FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: m.FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: m.FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}

/// Shape for model avatars still drawn as Material polygons.
final expressiveAvatarShape = MaterialShapes.cookie9Sided;
