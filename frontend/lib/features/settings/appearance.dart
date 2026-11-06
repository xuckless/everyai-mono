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
  const Appearance({required this.theme, this.pureBlack = false, this.reduceMotion = false});

  final ThemePreference theme;

  /// Animations off in the app, whatever the system says (the system setting already turns them off).
  final bool reduceMotion;

  /// Dark theme on a #000 background.
  final bool pureBlack;

  /// The app has one look on every platform. Screens not yet rebuilt on the
  /// kit render their Material layout under the single Material root.
  DesignLanguage get design => DesignLanguage.material;

  Brightness brightness(Brightness platform) => switch (theme) {
    ThemePreference.system => platform,
    ThemePreference.light => Brightness.light,
    ThemePreference.dark => Brightness.dark,
  };
}

final appearanceProvider = NotifierProvider<AppearanceController, Appearance>(AppearanceController.new);

final class AppearanceController extends Notifier<Appearance> {
  static const _themeKey = 'appearance.theme';
  static const _pureBlackKey = 'appearance.pure_black';
  static const _reduceMotionKey = 'appearance.reduce_motion';

  Preferences get _prefs => ref.read(preferencesProvider);

  @override
  Appearance build() {
    final prefs = ref.watch(preferencesProvider);
    return Appearance(
      theme: ThemePreference.values.asNameMap()[prefs[_themeKey]] ?? ThemePreference.system,
      pureBlack: prefs[_pureBlackKey] == 'true',
      reduceMotion: prefs[_reduceMotionKey] == 'true',
    );
  }

  void setTheme(ThemePreference theme) {
    _prefs[_themeKey] = theme.name;
    state = Appearance(theme: theme, pureBlack: state.pureBlack, reduceMotion: state.reduceMotion);
  }

  void setPureBlack(bool on) {
    _prefs[_pureBlackKey] = on ? 'true' : null;
    state = Appearance(theme: state.theme, pureBlack: on, reduceMotion: state.reduceMotion);
  }

  void setReduceMotion(bool on) {
    _prefs[_reduceMotionKey] = on ? 'true' : null;
    state = Appearance(theme: state.theme, pureBlack: state.pureBlack, reduceMotion: on);
  }
}
