// The EveryAI brand palette and role tokens, from brand/tokens (kit v1.0).
// EveryTheme.resolve maps the roles onto the app.

import 'package:flutter/widgets.dart';

abstract final class EveryPalette {
  static const violet50 = Color(0xFFF6F3FF);
  static const violet100 = Color(0xFFECE5FE);
  static const violet200 = Color(0xFFD7CCFF);
  static const violet300 = Color(0xFFBCADFF);
  static const violet400 = Color(0xFF9C85FC);
  static const violet500 = Color(0xFF7756E4);
  static const violet600 = Color(0xFF633FC7);
  static const violet700 = Color(0xFF4D2E9E);
  static const violet800 = Color(0xFF382074);
  static const violet900 = Color(0xFF24134D);
  static const violet950 = Color(0xFF14082D);

  static const cyan50 = Color(0xFFE7F9FE);
  static const cyan100 = Color(0xFFCAF4FE);
  static const cyan200 = Color(0xFF9CE9FC);
  static const cyan300 = Color(0xFF6ADDF7);
  static const cyan400 = Color(0xFF2CCCEB);
  static const cyan500 = Color(0xFF00B1CE);
  static const cyan600 = Color(0xFF068FA7);
  static const cyan700 = Color(0xFF007083);
  static const cyan800 = Color(0xFF00515F);
  static const cyan900 = Color(0xFF00343F);

  static const ink1000 = Color(0xFF000000);
  static const ink950 = Color(0xFF07070A);
  static const ink900 = Color(0xFF0E0E12);
  static const ink850 = Color(0xFF16161A);
  static const ink800 = Color(0xFF1F1F23);
  static const ink700 = Color(0xFF2B2B2F);
  static const ink600 = Color(0xFF424247);
  static const ink500 = Color(0xFF636368);
  static const ink400 = Color(0xFF85858B);
  static const ink300 = Color(0xFFAAAAB0);
  static const ink200 = Color(0xFFD0D0D6);
  static const ink100 = Color(0xFFEAEAF0);
  static const ink50 = Color(0xFFFAFAFE);

  static const primary = violet500;
  static const secondary = cyan400;
}

abstract final class EveryRolesDark {
  static const background = Color(0xFF07070A);
  static const backgroundOled = Color(0xFF000000);
  static const surface = Color(0xFF0E0E12);
  static const surfaceRaised = Color(0xFF16161A);
  static const overlay = Color(0xFF1F1F23);
  static const border = Color(0x14FFFFFF);
  static const text = Color(0xFFEAEAF0);
  static const textMuted = Color(0xFFAAAAB0);
  static const textSubtle = Color(0xFF85858B);
  static const accent = Color(0xFF9C85FC);
  static const accentText = Color(0xFFBCADFF);
  static const primary = Color(0xFF7756E4);
  static const onPrimary = Color(0xFFFFFFFF);
  static const link = Color(0xFF6ADDF7);
  static const focus = Color(0xFF2CCCEB);
  static const userBubble = Color(0xFF24134D);
  static const onUserBubble = Color(0xFFF6F3FF);
  static const codeBackground = Color(0xFF16161A);
  static const codeInline = Color(0xFFBCADFF);
  static const success = Color(0xFF59D38C);
  static const warning = Color(0xFFEFA831);
  static const danger = Color(0xFFFF958E);
}

abstract final class EveryRolesLight {
  static const background = Color(0xFFFAFAFE);
  static const backgroundOled = Color(0xFFFAFAFE);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceRaised = Color(0xFFF1F0F6);
  static const overlay = Color(0xFFFFFFFF);
  static const border = Color(0x1A0E0E12);
  static const text = Color(0xFF0E0E12);
  static const textMuted = Color(0xFF636368);
  static const textSubtle = Color(0xFF85858B);
  static const accent = Color(0xFF633FC7);
  static const accentText = Color(0xFF633FC7);
  static const primary = Color(0xFF7756E4);
  static const onPrimary = Color(0xFFFFFFFF);
  static const link = Color(0xFF007083);
  static const focus = Color(0xFF068FA7);
  static const userBubble = Color(0xFFECE5FE);
  static const onUserBubble = Color(0xFF24134D);
  static const codeBackground = Color(0xFFF1F0F6);
  static const codeInline = Color(0xFF633FC7);
  static const success = Color(0xFF027E47);
  static const warning = Color(0xFF8D5E00);
  static const danger = Color(0xFFAF3C3A);
}

abstract final class EveryMark {
  /// SVG path data on a 100x100 grid. Parse with path_drawing or flutter_svg.
  static const path =
      'M26 12H79A9 9 0 0 1 79 30H39A5 5 0 0 0 34 35V36A5 5 0 0 0 39 41H52A9 9 0 0 1 52 59H39A5 5 0 0 0 34 64V65A5 5 0 0 0 39 70H79A9 9 0 0 1 79 88H26A14 14 0 0 1 12 74V26A14 14 0 0 1 26 12Z';
  static const dotCenter = Offset(79, 50);
  static const dotRadius = 9.0;
}
