import 'package:cupertino_ui/cupertino_ui.dart' as c;
import 'package:fluent_ui/fluent_ui.dart' as f;
// macos_ui still builds on the framework's legacy Material library.
import 'package:flutter/material.dart' as legacy show ThemeMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart' as mac;
import 'package:material_ui/material_ui.dart' as m;

import '../core/platform/platform_kind.dart';
import '../core/theme/every_theme.dart';
import '../core/theme/native_themes.dart';
import '../features/settings/appearance.dart';
import 'router.dart';

/// Root widget. Picks the native app shell for the active design language, so
/// each platform gets its own navigation, theming, text selection and dialogs.
class EveryApp extends ConsumerWidget {
  const EveryApp({super.key});

  static const title = 'EveryAI';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final router = ref.watch(routerProvider);
    final design = appearance.design;

    Widget withTokens(BuildContext context, Widget? child) => EveryThemeScope(
      theme: EveryTheme.resolve(design, appearance.brightness(MediaQuery.platformBrightnessOf(context))),
      child: child ?? const SizedBox.shrink(),
    );

    final forced = switch (appearance.theme) {
      ThemePreference.system => null,
      ThemePreference.light => Brightness.light,
      ThemePreference.dark => Brightness.dark,
    };

    switch (design) {
      case DesignLanguage.cupertino:
        return c.CupertinoApp.router(
          title: title,
          debugShowCheckedModeBanner: false,
          routerConfig: router,
          theme: forced == null ? null : cupertinoTheme(forced),
          builder: (context, child) => withTokens(
            context,
            c.CupertinoTheme(
              data: cupertinoTheme(appearance.brightness(MediaQuery.platformBrightnessOf(context))),
              child: child!,
            ),
          ),
        );
      case DesignLanguage.macos:
        return mac.MacosApp.router(
          title: title,
          debugShowCheckedModeBanner: false,
          routerConfig: router,
          theme: macosTheme(Brightness.light),
          darkTheme: macosTheme(Brightness.dark),
          themeMode: switch (appearance.theme) {
            ThemePreference.system => legacy.ThemeMode.system,
            ThemePreference.light => legacy.ThemeMode.light,
            ThemePreference.dark => legacy.ThemeMode.dark,
          },
          builder: withTokens,
        );
      case DesignLanguage.fluent:
        return f.FluentApp.router(
          title: title,
          debugShowCheckedModeBanner: false,
          routerConfig: router,
          theme: fluentTheme(Brightness.light),
          darkTheme: fluentTheme(Brightness.dark),
          themeMode: switch (appearance.theme) {
            ThemePreference.system => f.ThemeMode.system,
            ThemePreference.light => f.ThemeMode.light,
            ThemePreference.dark => f.ThemeMode.dark,
          },
          builder: withTokens,
        );
      case DesignLanguage.material || DesignLanguage.adwaita:
        final adwaita = design == DesignLanguage.adwaita;
        return m.MaterialApp.router(
          title: title,
          debugShowCheckedModeBanner: false,
          routerConfig: router,
          theme: materialTheme(Brightness.light, adwaita: adwaita),
          darkTheme: materialTheme(Brightness.dark, adwaita: adwaita),
          themeMode: switch (appearance.theme) {
            ThemePreference.system => m.ThemeMode.system,
            ThemePreference.light => m.ThemeMode.light,
            ThemePreference.dark => m.ThemeMode.dark,
          },
          builder: withTokens,
        );
    }
  }
}
