import 'package:flutter/widgets.dart';

import '../../../core/ui/logos.dart';

import '../domain/model_catalog.dart';

/// A vendor's logo on its tile (Lobe Icons); vendors without one get their
/// initial on a colour derived from their slug.
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
  Widget build(BuildContext context) => LogoTile(
    logo: Logo.vendor(provider.slug),
    letters: lettersOf(provider),
    color: colorOf(provider),
    size: size,
    label: provider.label,
  );
}
