import 'package:flutter/foundation.dart';

/// Native design language the UI renders with.
///
/// Normally derived from the host platform. It can be overridden in
/// Settings → Appearance, which is how every look gets previewed from one machine.
enum DesignLanguage {
  /// iOS / iPadOS: Cupertino with Liquid Glass surfaces.
  cupertino,

  /// macOS: macos_ui sidebar/toolbar chrome with vibrancy.
  macos,

  /// Android and web: Material 3 Expressive.
  material,

  /// Windows 11: Fluent with Mica.
  fluent,

  /// Linux: GNOME / libadwaita conventions on top of Material primitives.
  adwaita;

  static DesignLanguage forPlatform({required bool isWeb, required TargetPlatform platform}) {
    if (isWeb) return DesignLanguage.material;
    return switch (platform) {
      TargetPlatform.iOS => DesignLanguage.cupertino,
      TargetPlatform.macOS => DesignLanguage.macos,
      TargetPlatform.windows => DesignLanguage.fluent,
      TargetPlatform.linux => DesignLanguage.adwaita,
      TargetPlatform.android || TargetPlatform.fuchsia => DesignLanguage.material,
    };
  }

  static DesignLanguage get host => forPlatform(isWeb: kIsWeb, platform: defaultTargetPlatform);

  String get label => switch (this) {
    cupertino => 'iOS (Liquid Glass)',
    macos => 'macOS',
    material => 'Material 3 Expressive',
    fluent => 'Windows 11 (Fluent)',
    adwaita => 'GNOME (Adwaita)',
  };

  /// Desktop languages use pointer-first density, hover states and keyboard shortcuts.
  bool get isDesktop => this == macos || this == fluent || this == adwaita;
}

/// Facts about the real host, independent of the chosen [DesignLanguage].
abstract final class Host {
  static bool get isWeb => kIsWeb;

  /// macOS windows keep their traffic lights over the sidebar whatever the
  /// design language.
  static bool get hasTrafficLights => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  static bool get isApple =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS);
  static bool get isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);
  static bool get isMobile =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);
}
