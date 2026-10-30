import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../../models/ui/model_avatar.dart';

/// Message input. Grows to 8 lines. On desktop and web, Enter sends and
/// Shift+Enter inserts a newline; on phones the keyboard's return key adds lines.
/// Typing `@` offers models to route this one message to.
class Composer extends ConsumerStatefulWidget {
  const Composer({
    super.key,
    required this.busy,
    required this.onSend,
    required this.onStop,
    this.placeholder = 'Message',
  });

  final bool busy;
  final ValueChanged<String> onSend;
  final VoidCallback onStop;
  final String placeholder;

  @override
  ConsumerState<Composer> createState() => ComposerState();
}

class ComposerState extends ConsumerState<Composer> {
  final _controller = TextEditingController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);

  /// The `@partial` token under the caret, if any.
  ({int start, String query})? _mention;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void focus() => _focus.requestFocus();

  bool get _canSend => !widget.busy && _controller.text.trim().isNotEmpty;

  void _send() {
    if (!_canSend) return;
    widget.onSend(_controller.text);
    _controller.clear();
    _focus.requestFocus();
  }

  void _onChanged() {
    final sel = _controller.selection;
    final text = _controller.text;
    ({int start, String query})? mention;
    if (sel.isValid && sel.isCollapsed) {
      final before = text.substring(0, sel.baseOffset);
      final m = RegExp(r'(^|\s)@([\w.\-]*)$').firstMatch(before);
      if (m != null) mention = (start: m.start + m.group(1)!.length, query: m.group(2)!);
    }
    setState(() => _mention = mention);
  }

  void _applyMention(String alias) {
    final m = _mention;
    if (m == null) return;
    final caret = _controller.selection.baseOffset;
    final text = _controller.text.replaceRange(m.start, caret, '@$alias ');
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: m.start + alias.length + 2),
    );
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || Host.isMobile) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
      // Composing (IME) input: let the input method commit first.
      if (_controller.value.composing.isValid && !_controller.value.composing.isCollapsed) {
        return KeyEventResult.ignored;
      }
      final suggestions = _suggestions();
      if (suggestions.isNotEmpty) {
        _applyMention(suggestions.first.$1);
      } else {
        _send();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape && widget.busy) {
      widget.onStop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  List<(String, ModelSpec)> _suggestions() {
    final m = _mention;
    if (m == null) return const [];
    return ref.read(modelCatalogProvider).mentionSuggestions(m.query).take(6).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final suggestions = _suggestions();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (suggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassSurface(
              padding: const EdgeInsets.all(6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (alias, spec) in suggestions)
                    AdaptiveListTile(
                      dense: true,
                      leading: ModelAvatar(spec.provider, size: 22),
                      title: Text('@$alias'),
                      subtitle: Text(spec.name),
                      onTap: () => _applyMention(alias),
                    ),
                ],
              ),
            ),
          ),
        GlassSurface(
          radius: theme.design == DesignLanguage.cupertino || theme.design == DesignLanguage.material
              ? 26
              : theme.radius + 4,
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Semantics(
                    label: 'Message input',
                    textField: true,
                    child: AdaptiveTextField(
                      controller: _controller,
                      focusNode: _focus,
                      placeholder: widget.placeholder,
                      minLines: 1,
                      maxLines: 8,
                      borderless: true,
                      keyboardType: TextInputType.multiline,
                      textInputAction: Host.isMobile ? TextInputAction.newline : TextInputAction.send,
                      autofocus: !Host.isMobile,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _SendButton(busy: widget.busy, enabled: _canSend, onSend: _send, onStop: widget.onStop),
            ],
          ),
        ),
      ],
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.busy, required this.enabled, required this.onSend, required this.onStop});

  final bool busy;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final active = busy || enabled;
    return Semantics(
      button: true,
      label: busy ? 'Stop generating' : 'Send message',
      child: GestureDetector(
        onTap: busy ? onStop : (enabled ? onSend : null),
        child: MouseRegion(
          cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? theme.accent : theme.text.withValues(alpha: 0.12),
            ),
            child: Icon(
              (busy ? EveryIcon.stop : EveryIcon.send).of(
                // The filled Cupertino glyphs are already circles; use the plain arrow inside our circle.
                theme.design == DesignLanguage.cupertino || theme.design == DesignLanguage.macos
                    ? DesignLanguage.material
                    : theme.design,
              ),
              size: 20,
              color: active ? theme.onAccent : theme.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}
