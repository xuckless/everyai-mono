import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../domain/code_session.dart';
import '../../code_providers.dart' show composerInsertProvider;
import '../../harness/everyai/scrub.dart';
import '../../panes/panes_providers.dart';
import '../../shells/shell_registry.dart';
import '../../shells/shells_providers.dart';
import '../console/bottom_drawer.dart' show isDrawerToggle;
import 'terminal_font.dart';

/// The terminal's own key filter, which runs before the shell gets a key: ⌃` toggles the drawer ([toggle]) instead.
/// It is handled here: a key the filter lets through goes to the shell, never up to the drawer's shortcut.
KeyEventResult terminalKeys(KeyEvent event, VoidCallback toggle) {
  if (!isDrawerToggle(event)) return KeyEventResult.ignored;
  if (event is KeyDownEvent) toggle();
  return KeyEventResult.handled;
}

/// A session's shells, in its folder (its worktree), kept running while the app is open.
class TerminalPane extends StatelessWidget {
  const TerminalPane({super.key, required this.session, this.onToggle});

  final CodeSessionInfo session;

  /// What ⌃` does inside the terminal: the drawer's toggle.
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) =>
      TerminalTabsView(owner: session.id, workingDir: session.workingDir, onToggle: onToggle);
}

/// Terminal tabs for [owner] (a session, or [homeTerminalOwner]): a row of tabs with + to open another, and the
/// showing tab's shell, started in [workingDir]. Right click copies the selection or pastes.
class TerminalTabsView extends ConsumerStatefulWidget {
  const TerminalTabsView({super.key, required this.owner, required this.workingDir, this.onToggle});

  final String owner;
  final String workingDir;
  final VoidCallback? onToggle;

  @override
  ConsumerState<TerminalTabsView> createState() => _TerminalTabsViewState();
}

class _TerminalTabsViewState extends ConsumerState<TerminalTabsView> {
  final _controllers = <String, TerminalController>{};

  TerminalController _controller(String id) => _controllers.putIfAbsent(id, TerminalController.new);

  SessionTerminal _shell(String id) => ref.read(sessionTerminalProvider(id).notifier);

  /// The xterm buffer tab [id] shows: its own shell's, or the followed shell's (see `shellTabId`).
  Terminal _terminalOf(String id) =>
      shellKeyOf(id) != null ? ref.read(shellViewProvider(id).notifier).terminal : _shell(id).terminal;

  /// Starts [id]'s shell after the next layout, so it starts at the view's size (a followed shell: replays its log).
  void _startAfterLayout(String id) => WidgetsBinding.instance.endOfFrame.then((_) {
    if (!mounted) return;
    if (shellKeyOf(id) != null) {
      ref.read(shellViewProvider(id).notifier).start();
    } else {
      _shell(id)
          .start(widget.workingDir, command: ref.read(terminalTabsProvider(widget.owner).notifier).takeCommand(id));
    }
  });

  @override
  void initState() {
    super.initState();
    _startAfterLayout(ref.read(terminalTabsProvider(widget.owner)).activeId);
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _copyOrPaste(String id) async {
    final terminal = _terminalOf(id);
    final controller = _controller(id);
    if (controller.selection case final selection?) {
      await Clipboard.setData(ClipboardData(text: terminal.buffer.getText(selection)));
      controller.clearSelection();
    } else if ((await Clipboard.getData(Clipboard.kTextPlain))?.text case final text?) {
      terminal.paste(text);
    }
  }

  /// A tab's name: its number, or the followed shell's title and id.
  String _labelOf(String tabId, int i) {
    if (shellKeyOf(tabId) case final key?) {
      final e = shellByKey(key);
      return e == null ? 'shell' : '${e.title} · ${e.id}';
    }
    return ref.read(terminalTabsProvider(widget.owner)).labels[tabId] ?? '${i + 1}';
  }

  String _shellCaption(ShellEntry? e) {
    if (e == null) return '';
    final who = switch (e.origin) {
      ShellOrigin.agent => 'Started by the agent',
      ShellOrigin.appRun => 'The app',
      ShellOrigin.check => 'A check',
      ShellOrigin.outside => 'Started by the lead',
    };
    final how = e.running ? (e.live?.interactive ?? false ? 'you can type here' : 'read-only') : 'exited ${e.exitCode}';
    return '$who · $how · ${e.cwd}';
  }

  /// Stop, Restart, copy and Send to agent for a followed shell.
  List<Widget> _shellActions(BuildContext context, String id, ShellEntry? e) {
    final terminal = _terminalOf(id);
    String selectedOrAll() {
      final sel = _controller(id).selection;
      if (sel != null) return terminal.buffer.getText(sel);
      return terminal.buffer.getText();
    }

    return [
      if (e?.running ?? false)
        AdaptiveIconButton(icon: EveryIcon.stop, tooltip: 'Stop', size: 15, onPressed: () => e!.live?.stop()),
      if (e?.restart case final restart?)
        AdaptiveIconButton(
          icon: EveryIcon.retry,
          tooltip: 'Restart',
          size: 15,
          onPressed: () async {
            await restart();
            // The new run has a row of its own: follow it in this tab's place.
            final now = ShellRegistry.instance.of(e!.session).where((x) => x.id == e.id).lastOrNull;
            if (now != null && mounted) {
              final tabs = ref.read(terminalTabsProvider(widget.owner).notifier);
              tabs.close(ref.read(terminalTabsProvider(widget.owner)).ids.indexOf(id));
              ref.invalidate(shellViewProvider(id));
              tabs.openShell(now.key);
            }
          },
        ),
      AdaptiveIconButton(
        icon: EveryIcon.copy,
        tooltip: 'Copy selection or all',
        size: 15,
        onPressed: () => Clipboard.setData(ClipboardData(text: selectedOrAll())),
      ),
      if (e != null)
        AdaptiveIconButton(
          icon: EveryIcon.send,
          tooltip: 'Send to agent',
          size: 15,
          onPressed: () {
            final sel = _controller(id).selection;
            var text = sel != null ? terminal.buffer.getText(sel) : terminal.buffer.getText();
            if (sel == null) {
              final lines = text.trimRight().split('\n');
              text = lines.sublist(lines.length > 80 ? lines.length - 80 : 0).join('\n');
            }
            // Raw output may hold secrets (an env dump, a token printed by a CLI): masked before the model sees it.
            final clean = Scrubber.forProject(e.cwd).redact(text.trimRight());
            ref
                .read(composerInsertProvider(widget.owner).notifier)
                .insert('Output of `${e.title}` (${e.id}):\n```\n$clean\n```\n');
            showAdaptiveToast(context, 'Added to your message');
          },
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final tabs = ref.watch(terminalTabsProvider(widget.owner));
    final tabsCtl = ref.read(terminalTabsProvider(widget.owner).notifier);
    final id = tabs.activeId;
    final followed = shellKeyOf(id) != null;
    final status = followed ? const TerminalStatus() : ref.watch(sessionTerminalProvider(id));
    final view = followed ? ref.watch(shellViewProvider(id)) : null;
    // A tab shown for the first time starts its shell.
    ref.listen(terminalTabsProvider(widget.owner).select((t) => t.activeId), (_, next) => _startAfterLayout(next));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final (i, tabId) in tabs.ids.indexed)
                        _Tab(
                          key: ValueKey('terminal.tab.$tabId'),
                          label: _labelOf(tabId, i),
                          shell: shellKeyOf(tabId) != null,
                          active: i == tabs.active,
                          closable: tabs.ids.length > 1,
                          onTap: () => tabsCtl.show(i),
                          onClose: () {
                            tabsCtl.close(i);
                            if (shellKeyOf(tabId) != null) ref.invalidate(shellViewProvider(tabId));
                          },
                        ),
                      AdaptiveIconButton(
                        key: const ValueKey('terminal.new-tab'),
                        icon: EveryIcon.add,
                        tooltip: 'New terminal',
                        size: 15,
                        onPressed: tabsCtl.add,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        followed
                            ? _shellCaption(view?.entry)
                            : status.exitCode != null
                            ? 'Exited (${status.exitCode})'
                            : widget.workingDir,
                        overflow: TextOverflow.ellipsis,
                        style: theme.type.caption.tint(theme.textSubtle),
                      ),
                    ],
                  ),
                ),
              ),
              if (followed)
                ..._shellActions(context, id, view?.entry)
              else
                AdaptiveIconButton(
                  icon: EveryIcon.retry,
                  tooltip: 'Restart shell',
                  size: 16,
                  onPressed: () => _shell(id).restart(widget.workingDir),
                ),
            ],
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: TerminalThemes.defaultTheme.background,
            child: TerminalView(
              _terminalOf(id),
              readOnly: followed && !(view?.entry?.live?.interactive ?? false),
              key: ValueKey('terminal.view.$id'),
              controller: _controller(id),
              autofocus: true,
              padding: const EdgeInsets.all(8),
              textStyle: TerminalStyle(
                fontFamily: 'GeistMono',
                fontFamilyFallback: terminalFontFallback,
                fontSize: EveryTheme.of(context).type.callout.fontSize!,
              ),
              onSecondaryTapDown: (_, _) => _copyOrPaste(id),
              onKeyEvent: (_, event) =>
                  widget.onToggle == null ? KeyEventResult.ignored : terminalKeys(event, widget.onToggle!),
            ),
          ),
        ),
      ],
    );
  }
}

/// One terminal tab: its number, highlighted when showing, with a × on hover when there are several.
class _Tab extends StatefulWidget {
  const _Tab({
    super.key,
    required this.label,
    this.shell = false,
    required this.active,
    required this.closable,
    required this.onTap,
    required this.onClose,
  });

  final String label;

  /// Follows a shell (a different icon, its title as the label).
  final bool shell;
  final bool active;
  final bool closable;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(right: 4),
          padding: EdgeInsets.fromLTRB(8, 3, widget.closable ? 4 : 8, 3),
          decoration: BoxDecoration(
            color: widget.active ? theme.accent.withValues(alpha: 0.14) : (_hover ? theme.hover : null),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AdaptiveIcon(
                widget.shell ? EveryIcon.activity : EveryIcon.command,
                size: 12,
                color: widget.active ? theme.accent : theme.textMuted,
              ),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.caption.mono.tint(widget.active ? theme.accent : theme.textMuted),
                ),
              ),
              if (widget.closable) ...[
                const SizedBox(width: 2),
                Opacity(
                  opacity: _hover || widget.active ? 1 : 0,
                  child: GestureDetector(
                    onTap: widget.onClose,
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: AdaptiveIcon(EveryIcon.close, size: 11, color: theme.textMuted),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
