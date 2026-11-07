import 'dart:async';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' as m show Tooltip;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/platform_kind.dart';
import '../../../core/motion/motion.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../attachments/attachment.dart';
import '../../attachments/attachment_input.dart';
import '../../attachments/ui/attachment_tray.dart';
import '../../models/domain/model_catalog.dart';
import '../../settings/settings_registry.dart' show SettingsSection;
import '../../settings/ui/settings_modal.dart' show showSettings;
import '../../skills/domain/skill_catalog.dart' show sessionSkills;
import '../../skills/skills_providers.dart' show installedSkillsProvider, skillSettingsProvider;
import '../../slash/code_commands.dart' show withEveryLeadCommands;
import '../../slash/native_commands.dart';
import '../../slash/slash_command.dart';
import '../../slash/slash_registry.dart';
import '../../slash/ui/slash_menu.dart';
import '../code_providers.dart' show codeProjectsProvider, composerInsertProvider;
import '../domain/agent_mode.dart';
import '../harness/harness.dart' show NativeCommand, NativeMode, nativeModeOf;
import '../uploads/uploads.dart';
import 'agent_menu.dart';
import '../../models/ui/model_avatar.dart';
import 'harness_logo.dart';
import '../domain/code_session.dart' show everyaiHarnessName;

/// The Code composer. Enter sends (or queues while the agent works),
/// Option-Enter interrupts and sends now, Esc stops. `/` at the start opens the
/// command menu. With an [agent], a strip on the box's top edge holds the
/// harness, Workflows, Skills and MCP, and the settings sit as quiet text
/// under the box (harness · model · effort), each part its own menu.
class CodeComposer extends ConsumerStatefulWidget {
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
    this.onSendQueuedNow,
    this.stopAll,
    this.placeholder = 'Ask for a change, or reply to the agent',
    this.leading,
    this.trailing,
    this.lineExtras = const [],
    this.agent,
    this.banner,
    this.meter,
    this.minLines = 1,
    this.autofocus = true,
    this.model,
    this.slashHost,
    this.project,
    this.attachKinds,
    this.commands,
    this.onUnlistedCommand,
    this.nativeModes,
    this.nativeMode,
    this.onNativeModeChanged,
    this.nativeBypass = false,
    this.onNativeBypass,
    this.harnessLabel = '',
    this.sessionId,
    this.prefill,
  });

  final bool busy;
  final AgentMode mode;
  final ValueChanged<AgentMode> onModeChanged;

  /// Sends or queues the message. A `false` or `Future<bool>` of false means nothing went out, and the composer puts
  /// the text and files back; anything else (callers that return nothing) counts as sent. `dynamic` so plain
  /// `void` callbacks still fit.
  final dynamic Function(String text, List<Attachment> files) onSend;
  final void Function(String text, List<Attachment> files)? onSteer;
  final VoidCallback? onStop;
  final List<String> queued;
  final ValueChanged<int>? onUnqueue;

  /// Sends queued message i now, interrupting the agent (as Option-Enter would have).
  final ValueChanged<int>? onSendQueuedNow;

  /// Beside Send/Stop while the session runs more than the lead's turn: the Stop all menu ([StopAllButton]).
  final Widget? stopAll;
  final String placeholder;

  /// Extra controls in the bottom row (the project picker; a remote
  /// session's model name).
  final Widget? leading;
  final Widget? trailing;

  /// More quiet parts after harness · model · effort under the box (the New session page's workspace, host and
  /// settings).
  final List<Widget> lineExtras;

  /// The harness, workflow, model and effort the session runs with: the
  /// strip and the settings line take their parts from it. Null: no strip,
  /// only the mode under the box (remote control).
  final AgentMenu? agent;

  /// Above everything (the session's [LimitBanner]).
  final Widget? banner;

  /// Tokens, cost and context ring, before send.
  final Widget? meter;
  final int minLines;
  final bool autofocus;

  /// The session's model: whether attached images reach it.
  final ModelSpec? model;

  /// What `/` commands can drive in an open session; null: only the mode and Stop.
  final CodeSlashHost? slashHost;

  /// The project folder: its own `/` commands show here.
  final String? project;

  /// The kinds of file that can be attached; null for any. A session mirrored
  /// from another computer takes pictures and text only, and photos are
  /// scaled down before they travel.
  final Set<AttachmentKind>? attachKinds;

  /// An outside harness's own `/` commands, which replace EveryAI's in the
  /// menu; the app actions they push out ([CodeSlashHost]'s rewind, commit,
  /// PR, cost and brief) move to the [SessionActionsButton]. Null: EveryAI's
  /// menu (the EveryAI harness).
  final List<SlashCommand>? commands;

  /// A typed `/name args` that isn't in an empty [commands] list (the harness
  /// hasn't listed them yet): it still goes to the harness as a command, not
  /// as a message with EveryAI's notes in front.
  final Future<String?> Function(String name, String args)? onUnlistedCommand;

  /// An outside harness's own modes ([NativeModeMenu]), which replace
  /// Ask / Auto-edit / Plan / Full auto in the picker; null or empty: ours.
  final List<NativeMode>? nativeModes;
  final String? nativeMode;
  final ValueChanged<String>? onNativeModeChanged;

  /// "Bypass EveryAI checks" under an outside lead's modes: on, and how to switch it.
  final bool nativeBypass;
  final ValueChanged<bool>? onNativeBypass;

  /// The harness's name, the native picker's header.
  final String harnessLabel;

  /// The open session: text other views send its way ([composerInsertProvider]) lands at the caret.
  final String? sessionId;

  /// Text to put in the box (from a link); a new [seq] replaces what is there. Never sent for the user.
  final ({String text, int seq})? prefill;

  @override
  ConsumerState<CodeComposer> createState() => _CodeComposerState();
}

class _CodeComposerState extends ConsumerState<CodeComposer> {
  /// When a queued message was last sent now or removed. The chips act by position, so the next message moves under
  /// the pointer: the second click of a double click would send or drop that one too. Clicks on the queue within a
  /// double click's length of the last are ignored.
  DateTime? _queueActedAt;

  void _queueAction(VoidCallback act) {
    final now = DateTime.now();
    if (_queueActedAt case final last? when now.difference(last) < kDoubleTapTimeout) return;
    _queueActedAt = now;
    act();
  }

  final _controller = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _onKey);
  final _files = <Attachment>[];
  final _slash = SlashMenuController(surface: SlashScope.code);

  @override
  void initState() {
    super.initState();
    _slash.project = widget.project;
    if (widget.prefill case final p?) _setDraft(p.text);
    _controller.addListener(() {
      _slash.update(_controller.value, _commands);
      setState(() {});
    });
  }

  List<SlashCommand> get _commands => switch (widget.commands) {
    final native? => withEveryLeadCommands(native),
    null => ref.read(slashCommandsProvider),
  };

  @override
  void didUpdateWidget(CodeComposer old) {
    super.didUpdateWidget(old);
    _slash.project = widget.project;
    if (widget.prefill case final p? when p.seq != old.prefill?.seq) _setDraft(p.text);
    // The harness listed its commands again while the menu may be open.
    if (!identical(old.commands, widget.commands)) _slash.update(_controller.value, _commands);
  }

  /// Puts a link's prompt in the box, after anything already typed there.
  void _setDraft(String text) {
    if (_controller.text.trim().isNotEmpty) text = '${_controller.text.trimRight()}\n\n$text';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _slash.dispose();
    super.dispose();
  }

  SlashContext get _slashContext => SlashContext(
    context: context,
    surface: SlashScope.code,
    setDraft: (text) => _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    ),
    send: (text) => widget.onSend(text, const []),
    code:
        widget.slashHost ??
        CodeSlashHost(
          setMode: (name) => widget.onModeChanged(AgentMode.values.byName(name)),
          stop: widget.busy ? widget.onStop : null,
        ),
  );

  /// Puts [text] at the caret (after the draft when the field never had focus), with a space before it when the
  /// draft runs into it.
  void _insert(String text) {
    final v = _controller.value;
    final at = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    final before = v.text.substring(0, at.start);
    final piece = before.isEmpty || RegExp(r'\s$').hasMatch(before) ? text : ' $text';
    _controller.value = TextEditingValue(
      text: v.text.replaceRange(at.start, at.end, piece),
      selection: TextSelection.collapsed(offset: at.start + piece.length),
    );
    _focus.requestFocus();
  }

  void _pickSlash(SlashCommand command) {
    runSlash(command, '', _slashContext);
    _focus.requestFocus();
  }

  /// `/name` then optional arguments; a path such as `/usr/bin is slow` isn't one.
  static final _commandLine = RegExp(r'^/([A-Za-z][\w:.-]*)(?:\s+([\s\S]*))?$');

  bool get _hasText => _controller.text.trim().isNotEmpty || _files.isNotEmpty;

  void _submit({bool steer = false}) {
    if (!_hasText) return;
    final text = _controller.text;
    if (_files.isEmpty) {
      if (parseSlashLine(text, _commands, SlashScope.code, project: widget.project) case final line?) {
        runSlash(line.command, line.args, _slashContext, complete: false);
        _focus.requestFocus();
        return;
      }
      final unlisted = widget.onUnlistedCommand;
      if (unlisted != null && widget.commands?.isEmpty == true) {
        if (_commandLine.firstMatch(text.trim()) case final m?) {
          final command = nativeSlashCommands([NativeCommand(name: m[1]!)], unlisted).single;
          runSlash(command, m[2]?.trim() ?? '', _slashContext, complete: false);
          _focus.requestFocus();
          return;
        }
      }
    }
    final files = List<Attachment>.unmodifiable(_files);
    // Cleared at once so sending feels instant; put back when the send says nothing went out.
    _controller.clear();
    setState(_files.clear);
    _focus.requestFocus();
    if (steer && widget.busy && widget.onSteer != null) {
      widget.onSteer!(text, files);
      return;
    }
    final Object? sent = widget.onSend(text, files);
    if (sent is Future<bool>) {
      unawaited(
        sent.then((ok) => _restoreUnless(ok, text, files), onError: (Object _) => _restoreUnless(false, text, files)),
      );
    } else if (sent == false) {
      _restoreUnless(false, text, files);
    }
  }

  void _restoreUnless(bool sent, String text, List<Attachment> files) {
    // Not if the user has started the next message meanwhile.
    if (sent || !mounted || _hasText) return;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() => _files.addAll(files));
  }

  /// Any file can go to the agent: it is saved into the project.
  Future<void> _add(List<XFile> picked) async {
    final added = await readPicked(
      picked,
      alreadyBytes: _files.fold(0, (sum, a) => sum + a.size),
      kinds: widget.attachKinds,
      onMessage: (message) {
        if (mounted) showAdaptiveToast(context, message);
      },
    );
    if (!mounted || added.isEmpty) return;
    setState(() => _files.addAll(added));
    _focus.requestFocus();
  }

  String get _filesNote {
    final m = widget.model;
    final images = _files.any((f) => f.kind == AttachmentKind.image);
    final blind = images && m != null && !m.accepts(AttachmentKind.image);
    return 'Saved to the project in $uploadsDir${blind ? ". ${m.name} can't see images; the agent can still open the files." : ''}';
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_slash.handleKey(event, _pickSlash) case final handled?) return handled;
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
    const radius = EveryTheme.composerRadius;
    if (widget.sessionId case final id?) {
      ref.listen(composerInsertProvider(id), (_, next) {
        if (next != null) _insert(next.text);
      });
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SlashMenu(controller: _slash, onPick: _pickSlash),
        if (widget.queued.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (i, q) in widget.queued.indexed)
                  _QueuedChip(
                    key: ValueKey('composer.queued.$i'),
                    text: q,
                    onRemove: widget.onUnqueue == null ? null : () => _queueAction(() => widget.onUnqueue!(i)),
                    onSendNow: widget.onSendQueuedNow == null
                        ? null
                        : () => _queueAction(() => widget.onSendQueuedNow!(i)),
                  ),
              ],
            ),
          ),
        ?widget.banner,
        AttachmentDropZone(
          onFiles: _add,
          child: GlassSurface(
            radius: radius,
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.agent case final agent? when agent.workflow != null && agent.onWorkflow != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: KitChip(
                        key: const ValueKey('composer.workflow-chip'),
                        label: agent.workflow!.title,
                        on: true,
                        leading: AdaptiveIcon(EveryIcon.workflow, size: 13),
                        trailing: Semantics(
                          button: true,
                          label: 'Remove workflow',
                          child: GestureDetector(
                            key: const ValueKey('composer.workflow-chip.remove'),
                            onTap: () => agent.onWorkflow!(null),
                            child: AdaptiveIcon(EveryIcon.close, size: 12),
                          ),
                        ),
                        onTap: () {},
                      ),
                    ).settle(),
                  ),
                AttachmentTray(
                  attachments: _files,
                  note: _filesNote,
                  onRemove: (a) => setState(() => _files.remove(a)),
                ),
                Semantics(
                  label: 'Message the agent',
                  textField: true,
                  child: AdaptiveTextField(
                    controller: _controller,
                    focusNode: _focus,
                    placeholder: widget.busy
                        ? 'Queue a message · ${Host.enterKeys(option: true)} sends now'
                        : widget.placeholder,
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
                    KitIconButton(
                      icon: EveryIcon.add,
                      tooltip: 'Attach files',
                      round: true,
                      size: 18,
                      onPressed: () async => _add(await pickAttachmentFiles(allowed: widget.attachKinds)),
                    ),
                    if (widget.slashHost case final host? when widget.commands != null)
                      SessionActionsButton(host: host),
                    const SizedBox(width: 2),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        primary: false,
                        child: Row(
                          children: [
                            _modeMenu(),
                            if (widget.agent case final agent? when agent.onWorkflow != null && !agent.demo)
                              AgentMenuPart(
                                key: const ValueKey('composer.strip.workflow'),
                                menu: agent,
                                page: AgentMenuPage.workflow,
                                trigger: (context, label, enabled) =>
                                    _RowChip(label: label, icon: EveryIcon.workflow, on: agent.workflow != null),
                              ),
                            if (widget.agent != null) _SkillsChip(project: widget.project),
                            if (widget.leading != null) ...[
                              const SizedBox(width: 4),
                              ConstrainedBox(constraints: const BoxConstraints(maxWidth: 240), child: widget.leading),
                            ],
                          ],
                        ),
                      ),
                    ),
                    ?widget.trailing,
                    ?widget.meter,
                    const SizedBox(width: 6),
                    if (widget.stopAll case final w?) ...[w, const SizedBox(width: 6)],
                    _CodeSend(
                      busy: widget.busy && widget.onStop != null && !_hasText,
                      hasText: _hasText,
                      queue: widget.busy,
                      onSend: _submit,
                      onStop: widget.onStop,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        _settingsLine(),
      ],
    );
  }

  /// The permission mode: EveryAI's, or the outside harness's own.
  Widget _modeMenu() {
    final modes = widget.nativeModes;
    return modes != null && modes.isNotEmpty && widget.onNativeModeChanged != null
        ? NativeModeMenu(
            harness: widget.harnessLabel,
            modes: modes,
            current: widget.nativeMode,
            policy: widget.mode,
            onChanged: widget.onNativeModeChanged!,
            bypass: widget.nativeBypass,
            onBypass: widget.onNativeBypass,
          )
        : ModeMenu(mode: widget.mode, onChanged: widget.onModeChanged);
  }

  /// harness · model · effort under the box, each its own menu, then [CodeComposer.lineExtras].
  Widget _settingsLine() {
    final theme = EveryTheme.of(context);
    final agent = widget.agent;
    if (agent == null && widget.lineExtras.isEmpty) return const SizedBox.shrink();
    final parts = [
      if (agent != null) ...[
        AgentMenuPart(
          key: const ValueKey('composer.strip.harness'),
          menu: agent,
          page: AgentMenuPage.harness,
          trigger: (context, label, enabled) =>
              QuietTrigger(label: label, enabled: enabled, leading: HarnessLogo(agent.harness, size: 14)),
        ),
        for (final page in agent.lineParts(ref))
          if (page != AgentMenuPage.workflow)
            AgentMenuPart(
              key: ValueKey('composer.line.${page.name}'),
              menu: agent,
              page: page,
              trigger: (context, label, enabled) => QuietTrigger(
                label: label,
                enabled: enabled,
                // EveryAI's models carry their vendor's logo; an outside harness's own model names don't map.
                leading: page == AgentMenuPage.model && agent.harness == everyaiHarnessName && agent.model.isNotEmpty
                    ? ModelAvatar(ModelProvider.ofModel(ModelId(agent.model)), size: 14)
                    : null,
              ),
            ),
      ],
      ...widget.lineExtras,
    ];
    final dot = Text(' · ', style: theme.type.caption.tint(theme.textSubtle));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final (i, part) in parts.indexed) ...[if (i > 0) dot, part],
        ],
      ),
    );
  }
}

/// A chip in the composer's row; the popover around it takes the tap.
class _RowChip extends StatelessWidget {
  const _RowChip({required this.label, this.icon, this.on = false, this.tint});

  final String label;
  final EveryIcon? icon;
  final bool on;
  final Color? tint;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: IgnorePointer(
      child: KitChip(
        label: label,
        on: on,
        tint: tint,
        chevron: true,
        leading: icon == null ? null : AdaptiveIcon(icon!, size: 14),
        onTap: () {},
      ),
    ),
  );
}

/// Skills: how many this session gets; opens their settings.
class _SkillsChip extends ConsumerWidget {
  const _SkillsChip({required this.project});

  final String? project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectId = project == null
        ? null
        : ref.watch(codeProjectsProvider).where((p) => p.path == project).firstOrNull?.id;
    final skills = sessionSkills(
      ref.watch(installedSkillsProvider).value ?? const [],
      ref.watch(skillSettingsProvider),
      projectId,
    ).length;
    return KitChip(
      key: const ValueKey('composer.strip.skills'),
      label: skills == 0 ? 'Skills' : 'Skills $skills',
      leading: AdaptiveIcon(EveryIcon.skill, size: 14),
      chevron: true,
      onTap: () => showSettings(context, section: SettingsSection.skills, args: {'project': ?projectId}),
    );
  }
}

/// Send (violet once there is text; queues while the agent works) or Stop.
class _CodeSend extends StatelessWidget {
  const _CodeSend({
    required this.busy,
    required this.hasText,
    required this.queue,
    required this.onSend,
    required this.onStop,
  });

  final bool busy;
  final bool hasText;
  final bool queue;
  final VoidCallback onSend;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final bg = busy ? theme.text : (hasText ? theme.primary : theme.overlay);
    final fg = busy ? theme.background : (hasText ? theme.onPrimary : theme.textSubtle);
    return m.Tooltip(
      message: busy ? 'Stop (Esc)' : (queue ? 'Queue' : 'Send'),
      child: Pressable(
        onTap: busy ? onStop : (hasText ? onSend : null),
        semanticLabel: busy ? 'Stop' : (queue ? 'Queue' : 'Send'),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 32,
          height: 32,
          decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
          child: IconSwap(
            child: busy
                ? Container(
                    key: const ValueKey('stop'),
                    width: 11,
                    height: 11,
                    decoration: BoxDecoration(color: fg, borderRadius: BorderRadius.circular(2.5)),
                  )
                : Icon(EveryIcon.send.data, key: const ValueKey('send'), size: 17, color: fg),
          ),
        ),
      ),
    );
  }
}

/// The app's session actions as a menu, for sessions whose `/` menu is the
/// harness's own: each row calls what its `/` command calls in an EveryAI
/// session. Model, Stop and the meter have controls of their own already.
class SessionActionsButton extends StatelessWidget {
  const SessionActionsButton({super.key, required this.host});

  final CodeSlashHost host;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return AdaptiveMenuButton(
      tooltip: 'Session actions',
      width: 220,
      actions: [
        if (host.rewind case final f?)
          MenuAction(label: 'Rewind last turn', icon: EveryIcon.retry, onSelected: () => f('')),
        if (host.commit case final f?) MenuAction(label: 'Commit…', icon: EveryIcon.check, onSelected: () => f('')),
        if (host.pr case final f?)
          MenuAction(label: 'Pull request…', icon: EveryIcon.external, onSelected: () => f('')),
        if (host.cost case final f?) MenuAction(label: 'Cost', icon: EveryIcon.usage, onSelected: f),
        if (host.morning case final f?) MenuAction(label: 'Morning brief', icon: EveryIcon.sun, onSelected: f),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: AdaptiveIcon(EveryIcon.more, size: 16, color: theme.textMuted),
      ),
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
    return AnchoredPopover(
      width: 280,
      // The popover closes before the Bypass confirmation, so that asks from this widget's context.
      // Scrolls when the window is too short for every mode.
      builder: (_, close) => SingleChildScrollView(
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
                onTap: () async {
                  close();
                  if (m == AgentMode.bypass && mode != AgentMode.bypass && !await confirmBypass(context)) return;
                  onChanged(m);
                },
              ),
          ],
        ),
      ),
      child: _ModeChip(label: mode.label, policy: mode),
    );
  }
}

/// An outside harness's own modes under its names (Claude Code's Default ·
/// Accept edits · Plan mode, Codex's presets, OpenCode's agents, an ACP
/// agent's modes). A greyed one can't be picked and says why. The chip's
/// colour comes from the [policy] the current one runs under. Below the modes,
/// the "Bypass EveryAI checks" switch ([onBypass]), which leaves the lead's
/// mode as it is.
class NativeModeMenu extends StatelessWidget {
  const NativeModeMenu({
    super.key,
    required this.harness,
    required this.modes,
    required this.current,
    required this.policy,
    required this.onChanged,
    this.bypass = false,
    this.onBypass,
  });

  final String harness;
  final List<NativeMode> modes;
  final String? current;
  final AgentMode policy;
  final ValueChanged<String> onChanged;

  /// EveryAI's checks are off for this session.
  final bool bypass;
  final ValueChanged<bool>? onBypass;

  Future<void> _toggleBypass(BuildContext context) async {
    if (!bypass && !await confirmBypass(context)) return;
    onBypass?.call(!bypass);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final label = nativeModeOf(modes, current)?.label ?? current ?? policy.label;
    return AnchoredPopover(
      width: 300,
      // Tall enough for the modes and the Bypass switch under them; a short window still caps it (and it scrolls).
      maxHeight: 640,
      // An agent may list many modes: the list scrolls rather than overflow. The popover closes before the Bypass
      // confirmation, so that asks from this widget's context.
      builder: (_, close) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PopoverHeader(harness.isEmpty ? 'Modes' : '$harness modes'),
            for (final m in modes)
              PopoverRow(
                title: m.label,
                subtitle: m.blocked ?? (m.description.isEmpty ? null : m.description),
                selected: m.id == current,
                trailing: m.id == current ? AdaptiveIcon(EveryIcon.check, size: 14, color: theme.accent) : null,
                onTap: m.blocked != null
                    ? null
                    : () {
                        close();
                        onChanged(m.id);
                      },
              ),
            if (onBypass != null) ...[
              Container(height: 1, color: theme.border, margin: const EdgeInsets.symmetric(vertical: 6)),
              PopoverRow(
                key: const ValueKey('composer.bypassChecks'),
                title: 'Bypass EveryAI checks',
                subtitle: "EveryAI's floor, rules and risk prompts off for this session",
                selected: bypass,
                trailing: IgnorePointer(
                  child: AdaptiveSwitch(value: bypass, onChanged: (_) {}),
                ),
                onTap: () {
                  close();
                  _toggleBypass(context);
                },
              ),
            ],
          ],
        ),
      ),
      child: _ModeChip(label: label, policy: bypass ? AgentMode.bypass : policy),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.label, required this.policy});
  final String label;
  final AgentMode policy;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final tint = switch (policy) {
      AgentMode.fullAuto || AgentMode.bypass => theme.danger,
      _ => null,
    };
    return Semantics(
      button: true,
      label: 'Mode: $label',
      child: _RowChip(label: label, tint: tint, on: policy == AgentMode.plan),
    );
  }
}

class _QueuedChip extends StatelessWidget {
  const _QueuedChip({super.key, required this.text, required this.onRemove, this.onSendNow});
  final String text;
  final VoidCallback? onRemove;
  final VoidCallback? onSendNow;

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
          Text('Queued · ', style: theme.type.caption.tint(theme.textMuted)),
          Flexible(
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.type.caption.tint(theme.text)),
          ),
          if (onSendNow != null)
            AdaptiveIconButton(
              key: const ValueKey('composer.queued.send-now'),
              icon: EveryIcon.send,
              tooltip: 'Send now (interrupts the agent)',
              size: 12,
              onPressed: onSendNow,
            ),
          if (onRemove != null)
            AdaptiveIconButton(icon: EveryIcon.close, tooltip: 'Remove', size: 12, onPressed: onRemove),
        ],
      ),
    );
  }
}

/// Asks before Bypass permissions turns every EveryAI check off.
Future<bool> confirmBypass(BuildContext context) => showAdaptiveConfirm(
  context,
  title: 'Bypass permissions?',
  message:
      'Every command and edit runs without asking, and EveryAI\'s checks are off too: the safety floor (rm -rf, '
      'force pushes, secrets), your deny rules and the warnings for risky commands or files outside the project. '
      'Forks, subagents and workflow agents of this session run the same way. Use it on a project you can restore.',
  confirmLabel: 'Bypass permissions',
  destructive: true,
);
