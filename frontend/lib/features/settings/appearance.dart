import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/platform_kind.dart';
import '../../core/preferences.dart';

enum ThemePreference {
  system('System'),
  light('Light'),
  dark('Dark');

  const ThemePreference(this.label);
  final String label;
}

@immutable
final class Appearance {
  const Appearance({required this.designOverride, required this.theme});

  /// Null follows the host platform.
  final DesignLanguage? designOverride;
  final ThemePreference theme;

  DesignLanguage get design => designOverride ?? DesignLanguage.host;

  Brightness brightness(Brightness platform) => switch (theme) {
    ThemePreference.system => platform,
    ThemePreference.light => Brightness.light,
    ThemePreference.dark => Brightness.dark,
  };
}

final appearanceProvider = NotifierProvider<AppearanceController, Appearance>(AppearanceController.new);

final class AppearanceController extends Notifier<Appearance> {
  static const _designKey = 'appearance.design';
  static const _themeKey = 'appearance.theme';

  Preferences get _prefs => ref.read(preferencesProvider);

  @override
  Appearance build() {
    final prefs = ref.watch(preferencesProvider);
    return Appearance(
      designOverride: DesignLanguage.values.asNameMap()[prefs[_designKey]],
      theme: ThemePreference.values.asNameMap()[prefs[_themeKey]] ?? ThemePreference.system,
    );
  }

  void setDesign(DesignLanguage? design) {
    _prefs[_designKey] = design?.name;
    state = Appearance(designOverride: design, theme: state.theme);
  }

  void setTheme(ThemePreference theme) {
    _prefs[_themeKey] = theme.name;
    state = Appearance(designOverride: state.designOverride, theme: theme);
  }
}
