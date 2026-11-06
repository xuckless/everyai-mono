import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../core/platform/window_caption.dart';
import '../core/motion/motion.dart';
import '../core/theme/every_theme.dart';
import '../core/theme/native_themes.dart';
import '../features/settings/appearance.dart';
import 'router.dart';

/// Root widget. One EveryAI look on every platform: Material is only the
/// plumbing (navigation, localizations, text editing, selection); everything
/// visible comes from the kit.
class EveryApp extends ConsumerWidget {
  const EveryApp({super.key});

  static const title = 'EveryAI';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final router = ref.watch(routerProvider);
    return m.MaterialApp.router(
      title: title,
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      scrollBehavior: const EveryScrollBehavior(),
      theme: kitMaterialTheme(Brightness.light),
      darkTheme: kitMaterialTheme(Brightness.dark, pureBlack: appearance.pureBlack),
      themeMode: switch (appearance.theme) {
        ThemePreference.system => m.ThemeMode.system,
        ThemePreference.light => m.ThemeMode.light,
        ThemePreference.dark => m.ThemeMode.dark,
      },
      builder: (context, child) => EveryThemeScope(
        theme: EveryTheme.resolve(
          appearance.design,
          appearance.brightness(MediaQuery.platformBrightnessOf(context)),
          pureBlack: appearance.pureBlack,
        ),
        // Windows/Linux: the window buttons float over every route and dialog.
        child: WindowButtonsOverlay(
          child: appearance.reduceMotion
              ? MediaQuery(
                  data: MediaQuery.of(context).copyWith(disableAnimations: true),
                  child: child ?? const SizedBox.shrink(),
                )
              : child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }
}
