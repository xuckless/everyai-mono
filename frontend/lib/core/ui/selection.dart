import 'package:cupertino_ui/cupertino_ui.dart' as c;
import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/cupertino.dart' as legacy_c;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../platform/platform_kind.dart';
import '../theme/every_theme.dart';

/// Makes descendant text selectable across widgets (whole chat transcripts),
/// with the platform's own handles and context menu.
class AdaptiveSelectionArea extends StatefulWidget {
  const AdaptiveSelectionArea({super.key, required this.child});

  final Widget child;

  @override
  State<AdaptiveSelectionArea> createState() => _AdaptiveSelectionAreaState();
}

class _AdaptiveSelectionAreaState extends State<AdaptiveSelectionArea> {
  final _focus = FocusNode(debugLabel: 'AdaptiveSelectionArea');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final design = EveryTheme.of(context).design;
    switch (design) {
      case DesignLanguage.material || DesignLanguage.adwaita:
        return m.SelectionArea(child: widget.child);
      case DesignLanguage.fluent:
        return f.SelectionArea(child: widget.child);
      case DesignLanguage.cupertino:
        return SelectableRegion(
          focusNode: _focus,
          selectionControls: c.cupertinoTextSelectionHandleControls,
          contextMenuBuilder: (context, state) => c.CupertinoAdaptiveTextSelectionToolbar.buttonItems(
            anchors: state.contextMenuAnchors,
            buttonItems: state.contextMenuButtonItems,
          ),
          child: widget.child,
        );
      case DesignLanguage.macos:
        // macos_ui builds on the legacy framework Cupertino library.
        return SelectableRegion(
          focusNode: _focus,
          selectionControls: legacy_c.cupertinoDesktopTextSelectionHandleControls,
          contextMenuBuilder: (context, state) => legacy_c.CupertinoAdaptiveTextSelectionToolbar.buttonItems(
            anchors: state.contextMenuAnchors,
            buttonItems: state.contextMenuButtonItems,
          ),
          child: widget.child,
        );
    }
  }
}
