import 'package:flutter/widgets.dart';

import '../platform/platform_kind.dart';
import 'every_type.dart';

export 'every_type.dart';
export 'everyai_brand.dart';

/// The EveryAI kit's tokens: one look on every platform (the "EveryAI" design
/// artifact, `project/everyai.css`). Screens read colours, radii and type from
/// here; nothing in a screen names a hex value.
@immutable
final class EveryTheme {
  const EveryTheme._({
    required this.design,
    required this.brightness,
    required this.pureBlack,
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.overlay,
    required this.well,
    required this.border,
    required this.borderStrong,
    required this.hover,
    required this.pressed,
    required this.text,
    required this.textMuted,
    required this.textSubtle,
    required this.accent,
    required this.accentText,
    required this.accentBg,
    required this.primary,
    required this.primaryHover,
    required this.onPrimary,
    required this.cyan,
    required this.cyanBg,
    required this.link,
    required this.userBubble,
    required this.onUserBubble,
    required this.success,
    required this.successBg,
    required this.warning,
    required this.warningBg,
    required this.danger,
    required this.dangerBg,
    required this.addBg,
    required this.delBg,
    required this.scrim,
    required this.shadowPop,
    required this.shadowSoft,
    required this.type,
  });

  factory EveryTheme.resolve(DesignLanguage design, Brightness brightness, {bool pureBlack = false, bool? touch}) {
    final type = EveryType.resolve(touch: touch);
    if (brightness == Brightness.dark) {
      return EveryTheme._(
        design: design,
        brightness: brightness,
        pureBlack: pureBlack,
        background: pureBlack ? const Color(0xFF000000) : const Color(0xFF07070A),
        surface: pureBlack ? const Color(0xFF09090C) : const Color(0xFF0E0E12),
        surfaceRaised: const Color(0xFF16161A),
        overlay: const Color(0xFF1A1A1F),
        well: const Color(0xFF121216),
        border: const Color(0x11FFFFFF),
        borderStrong: const Color(0x1CFFFFFF),
        hover: const Color(0x0BFFFFFF),
        pressed: const Color(0x14FFFFFF),
        text: const Color(0xFFEAEAF0),
        textMuted: const Color(0xFFAAAAB0),
        textSubtle: const Color(0xFF85858B),
        accent: const Color(0xFF9C85FC),
        accentText: const Color(0xFFBCADFF),
        accentBg: const Color(0x219C85FC),
        primary: const Color(0xFF7756E4),
        primaryHover: const Color(0xFF6A49D6),
        onPrimary: const Color(0xFFFFFFFF),
        cyan: const Color(0xFF2CCCEB),
        cyanBg: const Color(0x1F2CCCEB),
        link: const Color(0xFF6ADDF7),
        userBubble: const Color(0xFF24134D),
        onUserBubble: const Color(0xFFF6F3FF),
        success: const Color(0xFF59D38C),
        successBg: const Color(0x1F59D38C),
        warning: const Color(0xFFEFA831),
        warningBg: const Color(0x21EFA831),
        danger: const Color(0xFFFF958E),
        dangerBg: const Color(0x1FFF958E),
        addBg: const Color(0x1759D38C),
        delBg: const Color(0x17FF958E),
        scrim: const Color(0x8C000000),
        shadowPop: const [
          BoxShadow(color: Color(0xB3000000), offset: Offset(0, 16), blurRadius: 40, spreadRadius: -12),
          BoxShadow(color: Color(0x80000000), offset: Offset(0, 4), blurRadius: 12, spreadRadius: -4),
        ],
        shadowSoft: const [
          BoxShadow(color: Color(0x99000000), offset: Offset(0, 8), blurRadius: 24, spreadRadius: -12),
        ],
        type: type,
      );
    }
    return EveryTheme._(
      design: design,
      brightness: brightness,
      pureBlack: false,
      background: const Color(0xFFFAFAFE),
      surface: const Color(0xFFFFFFFF),
      surfaceRaised: const Color(0xFFF1F0F6),
      overlay: const Color(0xFFFFFFFF),
      well: const Color(0xFFF5F4FA),
      border: const Color(0x130E0E12),
      borderStrong: const Color(0x210E0E12),
      hover: const Color(0x0A0E0E12),
      pressed: const Color(0x130E0E12),
      text: const Color(0xFF0E0E12),
      textMuted: const Color(0xFF56565C),
      textSubtle: const Color(0xFF6B6B71),
      accent: const Color(0xFF633FC7),
      accentText: const Color(0xFF633FC7),
      accentBg: const Color(0x1A7756E4),
      primary: const Color(0xFF7756E4),
      primaryHover: const Color(0xFF6A49D6),
      onPrimary: const Color(0xFFFFFFFF),
      cyan: const Color(0xFF068FA7),
      cyanBg: const Color(0x1A068FA7),
      link: const Color(0xFF007083),
      userBubble: const Color(0xFFECE5FE),
      onUserBubble: const Color(0xFF24134D),
      success: const Color(0xFF027E47),
      successBg: const Color(0x17027E47),
      warning: const Color(0xFF8D5E00),
      warningBg: const Color(0x178D5E00),
      danger: const Color(0xFFAF3C3A),
      dangerBg: const Color(0x14AF3C3A),
      addBg: const Color(0x14027E47),
      delBg: const Color(0x12AF3C3A),
      scrim: const Color(0x470E0E12),
      shadowPop: const [
        BoxShadow(color: Color(0x380E0E12), offset: Offset(0, 16), blurRadius: 40, spreadRadius: -14),
        BoxShadow(color: Color(0x1A0E0E12), offset: Offset(0, 4), blurRadius: 10, spreadRadius: -4),
      ],
      shadowSoft: const [BoxShadow(color: Color(0x2E0E0E12), offset: Offset(0, 6), blurRadius: 18, spreadRadius: -10)],
      type: type,
    );
  }

  /// Kept while screens migrate off per-platform design languages; the kit
  /// renders the same on every value.
  final DesignLanguage design;
  final Brightness brightness;

  /// Dark theme on a #000 background (OLED).
  final bool pureBlack;

  /// Window background, behind the sidebar.
  final Color background;

  /// Main panels (chat, code session, board).
  final Color surface;

  /// Composer, soft buttons, segmented tracks.
  final Color surfaceRaised;

  /// Popovers, menus, the segmented indicator.
  final Color overlay;

  /// Recessed boxes: diffs, terminals, search fields.
  final Color well;

  /// Hairlines (inset 1px rings on cards); [borderStrong] for tracks and grabbers.
  final Color border;
  final Color borderStrong;
  final Color hover;
  final Color pressed;

  final Color text;
  final Color textMuted;
  final Color textSubtle;

  /// Violet for icons, rings and selection; [accentText] for violet text.
  final Color accent;
  final Color accentText;
  final Color accentBg;

  /// Violet 500 for filled controls, with [onPrimary] on top.
  final Color primary;
  final Color primaryHover;
  final Color onPrimary;

  /// The live-state colour: running dots, focus rings.
  final Color cyan;
  final Color cyanBg;
  final Color link;
  final Color userBubble;
  final Color onUserBubble;
  final Color success;
  final Color successBg;
  final Color warning;
  final Color warningBg;
  final Color danger;
  final Color dangerBg;
  final Color addBg;
  final Color delBg;
  final Color scrim;
  final List<BoxShadow> shadowPop;
  final List<BoxShadow> shadowSoft;

  /// The app's type scale; see [EveryType].
  final EveryType type;

  Color get codeBackground => well;

  /// Control radius (buttons, chips, menu rows).
  double get radius => 9;
  double get bubbleRadius => 18;

  /// Kit radii: rows 9, cards and popovers 14, panels 12, composer 18, sheets 22.
  static const rowRadius = 9.0;
  static const cardRadius = 14.0;
  static const popoverRadius = 14.0;
  static const panelRadius = 12.0;
  static const composerRadius = 18.0;
  static const sheetRadius = 22.0;
  static const bubbleTail = 6.0;

  BorderRadius get userBubbleShape => BorderRadius.only(
    topLeft: Radius.circular(bubbleRadius),
    topRight: Radius.circular(bubbleRadius),
    bottomLeft: Radius.circular(bubbleRadius),
    bottomRight: const Radius.circular(bubbleTail),
  );

  /// Hairline ring drawn inside a box (the kit's `inset 0 0 0 1px var(--line)`).
  Border get hairline => Border.all(color: border, width: 1);

  Color get signal => cyan;

  bool get isDark => brightness == Brightness.dark;

  static EveryTheme of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<EveryThemeScope>()!.theme;
}

class EveryThemeScope extends InheritedWidget {
  const EveryThemeScope({super.key, required this.theme, required super.child});

  final EveryTheme theme;

  @override
  bool updateShouldNotify(EveryThemeScope oldWidget) =>
      theme.design != oldWidget.theme.design ||
      theme.brightness != oldWidget.theme.brightness ||
      theme.pureBlack != oldWidget.theme.pureBlack;
}

/// Window-size classes: phone, tablet, desktop.
enum WindowSize {
  compact,
  medium,
  expanded;

  static WindowSize of(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return width < 600
        ? compact
        : width < 1100
        ? medium
        : expanded;
  }
}
