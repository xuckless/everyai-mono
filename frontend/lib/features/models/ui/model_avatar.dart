import 'package:flutter/widgets.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../domain/model_catalog.dart';

/// Provider logo, clipped to the design language's avatar shape: the
/// Expressive cookie on Material, a squircle on Apple, a circle elsewhere.
class ModelAvatar extends StatelessWidget {
  const ModelAvatar(this.provider, {super.key, this.size = 28});

  final ModelProvider provider;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final image = Image.asset(provider.asset, width: size, height: size, fit: BoxFit.cover);
    final clipped = switch (theme.design) {
      DesignLanguage.material => ClipPath(clipper: _PolygonClipper(MaterialShapes.cookie9Sided), child: image),
      DesignLanguage.cupertino ||
      DesignLanguage.macos => ClipRSuperellipse(borderRadius: BorderRadius.circular(size * 0.28), child: image),
      _ => ClipOval(child: image),
    };
    return Semantics(
      label: provider.label,
      image: true,
      child: SizedBox.square(dimension: size, child: clipped),
    );
  }
}

class _PolygonClipper extends CustomClipper<Path> {
  const _PolygonClipper(this.polygon);

  final RoundedPolygon polygon;

  @override
  Path getClip(Size size) {
    final path = polygon.toPath();
    final bounds = path.getBounds();
    final scale = Matrix4.identity()
      ..scaleByDouble(size.width / bounds.width, size.height / bounds.height, 1, 1)
      ..translateByDouble(-bounds.left, -bounds.top, 0, 1);
    return path.transform(scale.storage);
  }

  @override
  bool shouldReclip(_PolygonClipper old) => old.polygon != polygon;
}
