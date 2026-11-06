import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' as m;

/// Makes descendant text selectable across widgets (whole chat transcripts).
/// Material's selection area picks the host's own handles and context menu
/// (Cupertino on Apple hosts, desktop menus on desktops).
class AdaptiveSelectionArea extends StatelessWidget {
  const AdaptiveSelectionArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => m.SelectionArea(child: child);
}
