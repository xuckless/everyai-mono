import 'package:flutter/widgets.dart';

import 'every_icons.dart';
import 'kit.dart';

/// A row of pill buttons choosing one value, inline (no menu): usage ranges,
/// the theme, a settings scope. Give [icon] to show a glyph, alone when
/// [label] returns '' (the label then only names it for screen readers via
/// [semanticLabel]).
class AdaptiveSegmented<T> extends StatelessWidget {
  const AdaptiveSegmented({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
    this.icon,
    this.semanticLabel,
    this.enabled,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onSelected;
  final EveryIcon Function(T)? icon;
  final String Function(T)? semanticLabel;

  /// Which values can be picked (all by default).
  final bool Function(T)? enabled;

  @override
  Widget build(BuildContext context) => KitSegmented<T>(
    values: values,
    selected: selected,
    label: label,
    onSelected: onSelected,
    icon: icon,
    enabled: enabled,
    semanticLabel: semanticLabel,
  );
}
