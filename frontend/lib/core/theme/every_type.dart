import 'package:flutter/widgets.dart';

import '../platform/platform_kind.dart';

/// The app's one type scale. Every piece of text picks a role from here
/// (`EveryTheme.of(context).type.caption`) and adds only a color or, where it
/// must stand out, [EveryTypeWeights.medium] / [EveryTypeWeights.semibold].
/// Sizes never appear as literals in screens.
///
/// Two sizes per role: desktop (pointer, dense windows) and touch (phones and
/// tablets, a notch larger but lighter than iOS's 17pt defaults so text sits
/// level with the app's compact controls). Weights stop at semibold: bold SF
/// and Roboto read heavy at these sizes.
@immutable
final class EveryType {
  const EveryType({
    required this.largeTitle,
    required this.title,
    required this.headline,
    required this.body,
    required this.callout,
    required this.caption,
    required this.footnote,
    required this.micro,
  });

  factory EveryType.resolve({bool? touch}) {
    final t = touch ?? Host.isMobile;
    // Geist, tracked in ems like the kit: -0.005em on body, tighter on headings.
    TextStyle s(double desktop, double touch, {FontWeight w = FontWeight.w400, double em = -0.005, double h = 1.5}) {
      final size = t ? touch : desktop;
      return TextStyle(
        fontFamily: family,
        fontSize: size,
        fontWeight: w,
        letterSpacing: size * em,
        height: h,
        fontFeatures: const [FontFeature.enable('ss01'), FontFeature.enable('cv11')],
      );
    }

    return EveryType(
      largeTitle: s(24, 30, w: FontWeight.w600, em: -0.025, h: 1.2),
      title: s(17, 17, w: FontWeight.w600, em: -0.018, h: 1.3),
      headline: s(14.5, 16, w: FontWeight.w600, em: -0.012, h: 1.35),
      body: s(14.5, 15.5, h: 1.6),
      callout: s(13.5, 15),
      caption: s(12, 13, h: 1.4),
      footnote: s(11.5, 12, em: 0, h: 1.35),
      micro: s(10, 10.5, em: 0, h: 1.2),
    );
  }

  static const family = 'Geist';
  static const monoFamily = 'GeistMono';

  /// Screen and empty-state titles.
  final TextStyle largeTitle;

  /// Dialog, panel and card-group titles.
  final TextStyle title;

  /// Card and row titles that lead a block (semibold body).
  final TextStyle headline;

  /// Reading text, inputs, list-row titles, menu rows.
  final TextStyle body;

  /// Secondary text next to body: descriptions, tool rows, chips, buttons.
  final TextStyle callout;

  /// Metadata, subtitles, section labels, badges.
  final TextStyle caption;

  /// Fine print: timestamps, counts, keyboard hints.
  final TextStyle footnote;

  /// Tiny tags inside dense chrome (status pills, monogram letters).
  final TextStyle micro;
}

extension EveryTypeWeights on TextStyle {
  TextStyle get regular => copyWith(fontWeight: FontWeight.w400);
  TextStyle get medium => copyWith(fontWeight: FontWeight.w500);
  TextStyle get semibold => copyWith(fontWeight: FontWeight.w600);

  /// Monospace at the same role size (code, paths, keys).
  TextStyle get mono => copyWith(
    fontFamily: EveryType.monoFamily,
    fontSize: (fontSize ?? 14) * 0.9,
    letterSpacing: 0,
    fontFeatures: const [],
  );

  TextStyle tint(Color color) => copyWith(color: color);
}
