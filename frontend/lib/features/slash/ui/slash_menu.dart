import 'package:flutter/widgets.dart';

import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../slash_command.dart';

/// The `/` list above a composer: group headers, name with args hint and
/// description, the highlighted row kept in view. Empty when shut.
class SlashMenu extends StatefulWidget {
  const SlashMenu({super.key, required this.controller, required this.onPick, this.maxHeight = 320});

  final SlashMenuController controller;
  final ValueChanged<SlashCommand> onPick;
  final double maxHeight;

  @override
  State<SlashMenu> createState() => _SlashMenuState();
}

class _SlashMenuState extends State<SlashMenu> {
  final _keys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(SlashMenu old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = widget.controller;
      if (!mounted || !c.isOpen) return;
      final ctx = _keys[c.matches[c.highlight].name]?.currentContext;
      if (ctx == null) return;
      // Each policy only scrolls when the row is past its edge: together they keep it in view.
      Scrollable.ensureVisible(ctx, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      Scrollable.ensureVisible(ctx, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    if (!c.isOpen) return const SizedBox.shrink();
    final theme = EveryTheme.of(context);
    final rows = <Widget>[];
    SlashGroup? group;
    for (final (i, cmd) in c.matches.indexed) {
      if (cmd.group != group) {
        group = cmd.group;
        rows.add(PopoverHeader(group.label));
      }
      rows.add(
        _SlashRow(
          key: _keys.putIfAbsent(cmd.name, GlobalKey.new),
          command: cmd,
          highlighted: i == c.highlight,
          onHover: () => c.hover(i),
          onTap: () => widget.onPick(cmd),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        container: true,
        label: 'Commands',
        child: GlassSurface(
          level: GlassLevel.thick,
          radius: theme.design == DesignLanguage.fluent ? 8 : 14,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxHeight),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: rows,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SlashRow extends StatelessWidget {
  const _SlashRow({
    super.key,
    required this.command,
    required this.highlighted,
    required this.onHover,
    required this.onTap,
  });

  final SlashCommand command;
  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Semantics(
          button: true,
          selected: highlighted,
          label: '/${command.name}',
          child: Opacity(
            opacity: command.locked ? 0.5 : 1,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: highlighted ? theme.text.withValues(alpha: 0.08) : null,
                borderRadius: BorderRadius.circular(theme.radius - 2),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '/${command.name}',
                    style: TextStyle(color: theme.text, fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                  if (command.takesArgs) ...[
                    const SizedBox(width: 6),
                    Text(command.argsHint!, style: TextStyle(color: theme.textMuted, fontSize: 12.5)),
                  ],
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      command.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(color: theme.textMuted, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
