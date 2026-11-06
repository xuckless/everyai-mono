import 'package:flutter/widgets.dart';

import '../../../core/ui/logos.dart';
import '../board/board_providers.dart' show harnessMark;

/// A harness's logo on its tile (Claude Code, Codex, …), or its two-letter mark when Lobe Icons has none.
class HarnessLogo extends StatelessWidget {
  const HarnessLogo(this.harness, {super.key, this.size = 20, this.label});

  /// The harness id (`everyai`, `claude-code`, `acp:goose`, …).
  final String harness;
  final double size;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final mark = harnessMark(harness);
    return LogoTile(logo: Logo.harness(harness), letters: mark.letters, color: mark.color, size: size, label: label);
  }
}
