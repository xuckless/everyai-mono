import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../domain/agent_mode.dart';

/// The Code composer. Enter sends (or queues while the agent works),
/// ⌥Enter interrupts and sends now, Esc stops.
class CodeComposer extends StatefulWidget {
  const CodeComposer({
    super.key,
    required this.busy,
    required this.mode,
    required this.onModeChanged,
    required this.onSend,
    this.onSteer,
    this.onStop,
    this.queued = const [],
    this.onUnqueue,
    this.placeholder = 'Ask for a change, or reply to the agent',
    this.leading,
    this.trailing,
    this.minLines = 1,
    this.autofocus = true,
  });

  final bool busy;
  final AgentMode mode;
  final ValueChanged<AgentMode> onModeChanged;
  final ValueChanged<String> onSend;
  final ValueChanged<String>? onSteer;
  final VoidCallback? onStop;
  final List<String> queued;
  final ValueChanged<int>? onUnqueue;
  final String placeholder;

  /// Extra controls in the bottom row (project and model pickers).
  final Widget? leading;
  final Widget? trailing;
  final int minLines;
  final bool autofocus;

  @override
  State<CodeComposer> createState() => _CodeComposerState();
}

class _CodeComposerState extends State<CodeComposer> {
  final _controller = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _onKey);

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _hasText => _controller.text.trim().isNotEmpty;

  void _submit({bool steer = false}) {
    if (!_hasText) return;
    final text = _controller.text;
    (steer && widget.busy && widget.onSteer != null ? widget.onSteer! : widget.onSend)(text);
    _controller.clear();
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || Host.isMobile) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (keyboard.isShiftPressed) return KeyEventResult.ignored;
      final composing = _controller.value.composing;
      if (composing.isValid && !composing.isCollapsed) return KeyEventResult.ignored;
      _submit(steer: keyboard.isAltPressed);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && widget.busy && widget.onStop != null) {
      widget.onStop!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final radius = theme.design == DesignLanguage.fluent ? 8.0 : EveryTheme.cardRadius;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.queued.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (i, q) in widget.queued.indexed)
                  _QueuedChip(text: q, onRemove: widget.onUnqueue == null ? null : () => widget.onUnqueue!(i)),
              ],
            ),
          ),
        GlassSurface(
          radius: radius,
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                label: 'Message the agent',
                textField: true,
                child: AdaptiveTextField(
                  controller: _controller,
                  focusNode: _focus,
                  placeholder: widget.busy ? 'Queue a message (⌥↩ to send now)' : widget.placeholder,
                  minLines: widget.minLines,
                  maxLines: 10,
                  borderless: true,
                  keyboardType: TextInputType.multiline,
                  autofocus: widget.autofocus && !Host.isMobile,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  ModeMenu(mode: widget.mode, onChanged: widget.onModeChanged),
                  // Capped rather than flexible, so the free space all goes to the model label.
                  if (widget.leading != null) ...[
                    const SizedBox(width: 4),
                    ConstrainedBox(constraints: const BoxConstraints(maxWidth: 240), child: widget.leading),
                  ],
                  // The model sits at the right, next to send.
                  Expanded(
                    child: Align(alignment: Alignment.centerRight, child: widget.trailing ?? const SizedBox()),
                  ),
                  const SizedBox(width: 6),
                  if (widget.busy && widget.onStop != null && !_hasText)
                    AdaptiveIconButton(icon: EveryIcon.stop, tooltip: 'Stop (Esc)', onPressed: widget.onStop)
                  else
                    AdaptiveIconButton(
                      icon: EveryIcon.send,
                      tooltip: widget.busy ? 'Queue' : 'Send',
                      color: _hasText ? theme.accent : theme.textMuted,
                      onPressed: _hasText ? _submit : null,
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Ask · Auto-edit · Plan · Full auto.
class ModeMenu extends StatelessWidget {
  const ModeMenu({super.key, required this.mode, required this.onChanged});

  final AgentMode mode;
  final ValueChanged<AgentMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final color = switch (mode) {
      AgentMode.fullAuto => theme.danger,
      AgentMode.plan => theme.accent,
      _ => theme.textMuted,
    };
    return AnchoredPopover(
      width: 280,
      builder: (context, close) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PopoverHeader('Permissions'),
            for (final m in AgentMode.values)
              PopoverRow(
                title: m.label,
                subtitle: m.description,
                selected: m == mode,
                trailing: m == mode ? AdaptiveIcon(EveryIcon.check, size: 14, color: theme.accent) : null,
                onTap: () {
                  close();
                  onChanged(m);
                },
              ),
          ],
        ),
      ),
      child: Semantics(
        button: true,
        label: 'Mode: ${mode.label}',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            border: Border.all(color: color.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                mode.label,
                style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 4),
              AdaptiveIcon(EveryIcon.chevronDown, size: 11, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

class _QueuedChip extends StatelessWidget {
  const _QueuedChip({required this.text, required this.onRemove});
  final String text;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Queued · ', style: TextStyle(color: theme.textMuted, fontSize: 12)),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.text, fontSize: 12),
            ),
          ),
          if (onRemove != null)
            AdaptiveIconButton(icon: EveryIcon.close, tooltip: 'Remove', size: 12, onPressed: onRemove),
        ],
      ),
    );
  }
}
