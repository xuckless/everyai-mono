import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/brand.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../attachments/attachment.dart';
import '../../attachments/attachment_input.dart';
import '../../attachments/ui/attachment_tray.dart';
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../../models/ui/model_avatar.dart';
import '../domain/message.dart';
import 'model_picker.dart';

/// The message box: text on top, a tool bar underneath with
/// `+` (attach and tools), the answer mode, the model picker and send/stop.
///
/// Desktop and web: Enter sends, Shift+Enter adds a line, Esc stops.
/// Phones: return adds a line. `@alias` routes one message to another model.
class Composer extends ConsumerStatefulWidget {
  const Composer({
    super.key,
    required this.busy,
    required this.model,
    required this.mode,
    required this.onSend,
    required this.onStop,
    required this.onModelChanged,
    required this.onModeChanged,
    this.toolsEnabled = true,
    this.onToolsChanged,
    this.placeholder = 'How can I help you today?',
    this.minLines = 1,
    this.meter,
    this.replying = false,
  });

  final bool busy;

  /// The turn in flight waits on the user's answer (a question card): typed
  /// text can be sent as the reply even though [busy].
  final bool replying;
  final ModelSpec model;
  final ChatMode mode;
  final void Function(String text, List<Attachment> attachments) onSend;
  final VoidCallback onStop;
  final ValueChanged<ModelSpec> onModelChanged;
  final ValueChanged<ChatMode> onModeChanged;

  /// Rich answers: artifacts, diagrams, charts, quizzes, slides, images.
  final bool toolsEnabled;
  final ValueChanged<bool>? onToolsChanged;
  final String placeholder;

  /// The home screen's composer starts taller.
  final int minLines;

  /// Tokens, cost and context ring, beside the model picker.
  final Widget? meter;

  @override
  ConsumerState<Composer> createState() => ComposerState();
}

class ComposerState extends ConsumerState<Composer> {
  final _controller = TextEditingController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);
  ({int start, String query})? _mention;
  final _attachments = <Attachment>[];

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

  /// Puts text in the box (starter prompts) and focuses it.
  void prefill(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focus.requestFocus();
  }

  /// Attachments the selected model can't read; sending waits until they go.
  List<Attachment> get _blocked => [
    for (final a in _attachments)
      if (a.unsupportedBy(widget.model) != null) a,
  ];

  bool get _canSend => widget.busy
      ? widget.replying && _controller.text.trim().isNotEmpty && _attachments.isEmpty
      : (_controller.text.trim().isNotEmpty || _attachments.isNotEmpty) && _blocked.isEmpty;

  /// The send button stops the turn unless a reply is ready to go.
  bool get _showsStop => widget.busy && !_canSend;

  void _send() {
    if (!_canSend) return;
    widget.onSend(_controller.text, List.unmodifiable(_attachments));
    _controller.clear();
    setState(_attachments.clear);
    _focus.requestFocus();
  }

  /// Adds picked or dropped files; ones over a size limit are reported, not added.
  Future<void> addFiles(List<XFile> files) async {
    final added = await readAttachments(
      files,
      alreadyBytes: _attachments.fold(0, (sum, a) => sum + a.size),
      onError: (message) {
        if (mounted) showAdaptiveToast(context, message);
      },
    );
    if (!mounted || added.isEmpty) return;
    setState(() => _attachments.addAll(added));
    _focus.requestFocus();
  }

  Future<void> _pick() async {
    final files = await pickAttachmentFiles(allowed: AttachmentKind.values.where(widget.model.accepts).toSet());
    await addFiles(files);
  }

  void _onChanged() {
    final sel = _controller.selection;
    ({int start, String query})? mention;
    if (sel.isValid && sel.isCollapsed) {
      final before = _controller.text.substring(0, sel.baseOffset);
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

  List<(String, ModelSpec)> _suggestions() {
    final m = _mention;
    if (m == null) return const [];
    return ref.read(modelCatalogProvider).mentionSuggestions(m.query).take(6).toList();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || Host.isMobile) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
      final composing = _controller.value.composing;
      if (composing.isValid && !composing.isCollapsed) return KeyEventResult.ignored;
      final suggestions = _suggestions();
      suggestions.isNotEmpty ? _applyMention(suggestions.first.$1) : _send();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && widget.busy) {
      widget.onStop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final suggestions = _suggestions();
    // Brand card radius; Fluent stays native-tight.
    final radius = theme.design == DesignLanguage.fluent ? 8.0 : EveryTheme.cardRadius;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (suggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassSurface(
              level: GlassLevel.thick,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (alias, spec) in suggestions)
                    PopoverRow(
                      leading: ModelAvatar(spec.provider, size: 20),
                      title: '@$alias',
                      subtitle: spec.name,
                      onTap: () => _applyMention(alias),
                    ),
                ],
              ),
            ),
          ),
        AttachmentDropZone(
          onFiles: addFiles,
          child: GlassSurface(
            radius: radius,
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AttachmentTray(
                  attachments: _attachments,
                  model: widget.model,
                  suggestion: _blocked.isEmpty
                      ? null
                      : modelForAll(_attachments.map((a) => a.kind), ref.watch(libraryProvider).value ?? const []),
                  onSwitchModel: widget.busy ? null : widget.onModelChanged,
                  onRemove: (a) => setState(() => _attachments.remove(a)),
                ),
                Semantics(
                  label: 'Message',
                  textField: true,
                  child: AdaptiveTextField(
                    controller: _controller,
                    focusNode: _focus,
                    placeholder: widget.placeholder,
                    minLines: widget.minLines,
                    maxLines: 10,
                    borderless: true,
                    keyboardType: TextInputType.multiline,
                    textInputAction: Host.isMobile ? TextInputAction.newline : TextInputAction.send,
                    autofocus: !Host.isMobile,
                  ),
                ),
                const SizedBox(height: 10),
                LayoutBuilder(
                  // Narrow composers (beside the artifact panel, phones) fold the
                  // mode switcher into a menu.
                  builder: (context, constraints) => Row(
                    children: [
                      _ToolsButton(
                        model: widget.model,
                        onAttach: _pick,
                        mode: widget.mode,
                        onModeChanged: widget.onModeChanged,
                        toolsEnabled: widget.toolsEnabled,
                        onToolsChanged: widget.onToolsChanged,
                      ),
                      const SizedBox(width: 4),
                      if (constraints.maxWidth < 560)
                        _ModeMenu(mode: widget.mode, onChanged: widget.onModeChanged)
                      else
                        _ModeSelector(mode: widget.mode, onChanged: widget.onModeChanged),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: ModelChip(
                            selected: widget.model,
                            enabled: !widget.busy,
                            onSelected: widget.onModelChanged,
                          ),
                        ),
                      ),
                      ?widget.meter,
                      const SizedBox(width: 6),
                      _SendButton(busy: _showsStop, enabled: _canSend, onSend: _send, onStop: widget.onStop),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// `+`: attachments and tools. Attachments and connectors arrive with the agentic
/// roadmap; entries are visible so the surface is in place.
class _ToolsButton extends StatelessWidget {
  const _ToolsButton({
    required this.model,
    required this.onAttach,
    required this.mode,
    required this.onModeChanged,
    required this.toolsEnabled,
    required this.onToolsChanged,
  });

  final ModelSpec model;
  final VoidCallback onAttach;
  final ChatMode mode;
  final ValueChanged<ChatMode> onModeChanged;
  final bool toolsEnabled;
  final ValueChanged<bool>? onToolsChanged;

  /// "Images, PDFs, text and code" for what [model] reads.
  String get _attachHint {
    final kinds = [
      if (model.accepts(AttachmentKind.image)) 'images',
      if (model.accepts(AttachmentKind.pdf)) 'PDFs',
      if (model.accepts(AttachmentKind.audio)) 'audio',
      'text and code',
    ];
    final list = kinds.length == 1 ? kinds.first : '${kinds.take(kinds.length - 1).join(', ')} and ${kinds.last}';
    return '${list[0].toUpperCase()}${list.substring(1)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    Widget icon(EveryIcon i) => AdaptiveIcon(i, size: 16, color: theme.textMuted);
    return AnchoredPopover(
      width: 260,
      builder: (context, close) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PopoverRow(
              leading: icon(EveryIcon.attach),
              title: 'Add files or photos',
              subtitle: _attachHint,
              onTap: () {
                close();
                onAttach();
              },
            ),
            PopoverRow(
              leading: const BrandGlyph('search', size: 18),
              title: 'Web search',
              subtitle: 'Answer with cited sources',
              trailing: mode == ChatMode.search ? AdaptiveIcon(EveryIcon.check, size: 14, color: theme.accent) : null,
              onTap: () {
                close();
                onModeChanged(mode == ChatMode.search ? ChatMode.chat : ChatMode.search);
              },
            ),
            PopoverRow(
              leading: const BrandGlyph('artifacts', size: 18),
              title: 'Rich answers',
              subtitle: 'Documents, diagrams, charts, quizzes, slides',
              trailing: toolsEnabled ? AdaptiveIcon(EveryIcon.check, size: 14, color: theme.accent) : null,
              onTap: onToolsChanged == null
                  ? null
                  : () {
                      close();
                      onToolsChanged!(!toolsEnabled);
                    },
            ),
            PopoverRow(
              leading: const BrandGlyph('extended-thinking', size: 18),
              title: 'Extended thinking',
              subtitle: 'Coming soon',
            ),
            Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 6), color: theme.border),
            PopoverRow(
              leading: const BrandGlyph('connectors', size: 18),
              title: 'Connectors (MCP)',
              subtitle: 'Coming soon',
            ),
          ],
        ),
      ),
      child: _RoundIcon(icon: EveryIcon.add, tooltip: 'Add files and tools'),
    );
  }
}

/// Chat · Search · Research. A compact segmented control.
/// The answer mode as one pill with a menu, for narrow composers.
class _ModeMenu extends StatelessWidget {
  const _ModeMenu({required this.mode, required this.onChanged});

  final ChatMode mode;
  final ValueChanged<ChatMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return AnchoredPopover(
      width: 240,
      builder: (context, close) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final m in ChatMode.values)
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
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: theme.text.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(9)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              mode.label,
              style: TextStyle(color: theme.text, fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 3),
            AdaptiveIcon(EveryIcon.chevronDown, size: 11, color: theme.textMuted),
          ],
        ),
      ),
    );
  }
}

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({required this.mode, required this.onChanged});

  final ChatMode mode;
  final ValueChanged<ChatMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: theme.text.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(9)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in ChatMode.values)
            Semantics(
              button: true,
              selected: m == mode,
              label: '${m.label} mode',
              child: GestureDetector(
                onTap: () => onChanged(m),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: m == mode ? theme.surface : null,
                      borderRadius: BorderRadius.circular(7),
                      boxShadow: m == mode
                          ? const [BoxShadow(color: Color(0x22000000), blurRadius: 3, offset: Offset(0, 1))]
                          : null,
                    ),
                    child: Text(
                      m.label,
                      style: TextStyle(
                        color: m == mode ? theme.text : theme.textMuted,
                        fontSize: 12.5,
                        fontWeight: m == mode ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RoundIcon extends StatefulWidget {
  const _RoundIcon({required this.icon, required this.tooltip});

  final EveryIcon icon;
  final String tooltip;

  @override
  State<_RoundIcon> createState() => _RoundIconState();
}

class _RoundIconState extends State<_RoundIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: theme.border),
            color: _hover ? theme.text.withValues(alpha: 0.07) : null,
          ),
          child: Center(child: AdaptiveIcon(widget.icon, size: 16, color: theme.text)),
        ),
      ),
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
    // Plain glyphs inside our own filled circle, in every design language.
    final glyph = (busy ? EveryIcon.stop : EveryIcon.send).of(DesignLanguage.material);
    return Semantics(
      button: true,
      label: busy ? 'Stop generating' : 'Send message',
      child: GestureDetector(
        onTap: busy ? onStop : (enabled ? onSend : null),
        child: MouseRegion(
          cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: active ? theme.primary : theme.text.withValues(alpha: 0.10),
            ),
            child: Icon(glyph, size: 19, color: active ? theme.onPrimary : theme.textMuted),
          ),
        ),
      ),
    );
  }
}
