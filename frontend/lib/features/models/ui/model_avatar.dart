import 'package:flutter/widgets.dart';

import '../../../core/ui/kit.dart';
import '../domain/model_catalog.dart';

/// A vendor's coloured monogram (no third-party logos): C for Claude, O for
/// OpenAI, G for Gemini, E for EveryAI · Auto; other vendors get their initial
/// on a colour derived from their slug.
class ModelAvatar extends StatelessWidget {
  const ModelAvatar(this.provider, {super.key, this.size = 28});

  final ModelProvider provider;
  final double size;

  static Color colorOf(ModelProvider p) => switch (p.slug) {
    'everyai' => const Color(0xFF7756E4),
    'anthropic' => const Color(0xFFC9694A),
    'openai' => const Color(0xFF2B2B2F),
    'google' => const Color(0xFF3B6FE0),
    'x-ai' => const Color(0xFF3A3A40),
    'meta-llama' => const Color(0xFF1E62D0),
    _ => HSLColor.fromAHSL(
      1,
      (p.slug.codeUnits.fold(7, (h, c) => (h * 31 + c) & 0xffff) % 360).toDouble(),
      0.42,
      0.42,
    ).toColor(),
  };

  static String lettersOf(ModelProvider p) => switch (p.slug) {
    'everyai' => 'E',
    'openai' => 'O',
    _ => p.label.isEmpty ? '?' : p.label[0].toUpperCase(),
  };

  @override
  Widget build(BuildContext context) => Semantics(
    label: provider.label,
    image: true,
    child: AgentGlyph(letters: lettersOf(provider), color: colorOf(provider), size: size),
  );
}
