import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/motion/motion.dart';
import '../../../core/ui/brand.dart';
import '../../../core/ui/every_icons.dart';
import '../../chat/chat_providers.dart';
import '../../chat/data/chat_repository.dart';
import '../../chat/domain/message.dart';
import '../../code/code_providers.dart';
import '../../code/domain/code_session.dart';
import '../../code/environments/environment_picker.dart';
import '../../code/environments/environment_providers.dart';
import '../../code/environments/exec_env.dart';
import '../../code/ui/code_home.dart';
import '../../remote/ui/remote_code.dart' show RemoteSessionList;
import '../../settings/ui/account_menu.dart';
import '../../updates/ui/update_banner.dart';
import '../../../core/preferences.dart';
import '../../../core/platform/window_caption.dart' show WindowDragArea;

/// The app sidebar: Chat | Code, destinations, the recent list, the account.
/// On wide windows it collapses away entirely (pages then show a button to
/// bring it back); on phones it is a drawer.
class Sidebar extends ConsumerStatefulWidget {
  const Sidebar({
    super.key,
    required this.location,
    required this.onNavigate,
    required this.onToggle,
    this.compact = false,
  });

  final String location;

  /// A phone drawer: touch-sized rows, no collapse button.
  final bool compact;
  final ValueChanged<String> onNavigate;
  final VoidCallback onToggle;

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _debounce;
  bool _searching = false;

  /// The Code sessions query (chats search through [_matches] instead).
  String _codeQuery = '';

  /// Null when the query is empty; otherwise the matching conversation ids.
  Set<String>? _matches;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  @override
  void didUpdateWidget(Sidebar old) {
    super.didUpdateWidget(old);
    // A query belongs to the space it was typed in.
    if (old.location.startsWith(Routes.code) != widget.location.startsWith(Routes.code) && _searching) _closeSearch();
  }

  void _closeSearch() {
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _searching = false;
      _matches = null;
      _codeQuery = '';
    });
  }

  void _onQuery(String query) {
    if (widget.location.startsWith(Routes.code)) {
      setState(() => _codeQuery = query);
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () async {
      if (query.trim().isEmpty) {
        if (mounted) setState(() => _matches = null);
        return;
      }
      final ids = await ref.read(chatRepositoryProvider).search(query);
      final lower = query.toLowerCase();
      final all = ref.read(conversationsProvider).value ?? const [];
      if (!mounted) return;
      setState(
        () => _matches = {
          ...ids,
          for (final c in all)
            if (c.title.toLowerCase().contains(lower)) c.id,
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    // The title-bar row is shared with the traffic lights on any macOS window.
    final lights = Host.hasTrafficLights;
    final touch = widget.compact;
    final loc = widget.location;
    final newKeys = Host.isApple ? '⌘N' : 'Ctrl+N';

    final codeMode = loc.startsWith(Routes.code);
    final destinations = codeMode
        ? <_Destination>[
            // Sessions start on the computer; other devices list them.
            if (Host.isDesktop)
              _Destination(EveryIcon.add, 'New session', loc == Routes.code, Routes.code)
            else
              _Destination(EveryIcon.projects, 'Sessions', loc == Routes.code, Routes.code),
            if (Host.isDesktop) _Destination(EveryIcon.board, 'Board', loc == Routes.board, Routes.board),
            if (Host.isDesktop)
              _Destination(
                EveryIcon.search,
                'Search',
                _searching,
                null,
                onTap: _searching ? _closeSearch : _openSearch,
              ),
            _Destination(EveryIcon.models, 'Models', loc == Routes.models, Routes.models),
          ]
        : <_Destination>[
            _Destination(
              EveryIcon.newChat,
              'New chat',
              loc.startsWith('/chat/') && _isBlankChat(loc),
              Routes.newChat,
              keys: Host.isDesktop ? newKeys : null,
            ),
            _Destination(EveryIcon.search, 'Search', _searching, null, onTap: _searching ? _closeSearch : _openSearch),
            _Destination(EveryIcon.chat, 'Chats', loc == Routes.chats, Routes.chats),
            _Destination(EveryIcon.projects, 'Projects', loc == Routes.projects, Routes.projects),
            _Destination(EveryIcon.artifacts, 'Artifacts', loc == Routes.artifacts, Routes.artifacts),
            _Destination(EveryIcon.models, 'Models', loc == Routes.models, Routes.models),
          ];

    // On Windows/Linux the title row also moves the window (beside the caption strip over the panel).
    final header = WindowDragArea(
      child: SizedBox(
        height: touch ? 52 : 48,
        child: Padding(
          // macOS: the title-bar row, clear of the traffic lights.
          padding: EdgeInsets.only(left: lights && !touch ? 78 : 14, right: 6),
          child: Row(
            children: [
              if (!lights || touch)
                Semantics(
                  label: 'EveryAI',
                  child: BrandMark(size: touch ? 22 : 18),
                ),
              const Spacer(),
              if (!touch) _toggleButton(),
            ],
          ),
        ),
      ),
    );

    final top = <Widget>[
      header,
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 2, 10, 10),
        child: KitSegmented<bool>(
          key: const ValueKey('sidebar.space'),
          values: const [false, true],
          selected: codeMode,
          touch: touch,
          width: double.infinity,
          label: (code) => code ? 'Code' : 'Chat',
          onSelected: (code) => widget.onNavigate(code ? Routes.code : Routes.newChat),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, d) in destinations.indexed)
              _NavItem(
                icon: d.icon,
                label: d.label,
                selected: d.selected,
                keys: d.keys,
                touch: touch,
                onTap: d.onTap ?? () => widget.onNavigate(d.route!),
              ).rowIn(i),
          ],
        ),
      ),
      if (_searching && (!codeMode || Host.isDesktop))
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
          child: CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.escape): _closeSearch},
            child: AdaptiveTextField(
              controller: _search,
              focusNode: _searchFocus,
              placeholder: codeMode ? 'Search sessions' : 'Search chats',
              prefix: AdaptiveIcon(EveryIcon.search, size: 15, color: theme.textSubtle),
              onChanged: _onQuery,
              textInputAction: TextInputAction.search,
            ),
          ).settle(),
        ),
    ];
    return LayoutBuilder(
      builder: (context, box) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // On a short window the fixed top takes at most 60% of the height and scrolls; the list keeps the rest.
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: box.maxHeight.isFinite ? box.maxHeight * 0.6 : double.infinity),
            child: SingleChildScrollView(
              primary: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: top,
              ),
            ),
          ),
          Expanded(
            child: codeMode
                ? CodeSessionList(location: loc, query: _codeQuery, onNavigate: widget.onNavigate)
                : _Recents(location: loc, matches: _matches, onNavigate: widget.onNavigate),
          ),
          const UpdateBanner(collapsed: false),
          const AccountRow(collapsed: false),
        ],
      ),
    );
  }

  Widget _toggleButton() =>
      AdaptiveIconButton(icon: EveryIcon.sidebar, tooltip: 'Collapse sidebar', onPressed: widget.onToggle);

  /// The current chat is "new" when it has no stored conversation yet.
  bool _isBlankChat(String location) {
    final id = location.substring('/chat/'.length);
    final all = ref.watch(conversationsProvider).value;
    return all != null && !all.any((c) => c.id == id);
  }
}

/// [sessions] that match [query] (title, branch or project name; case-insensitive); all when it is blank.
List<CodeSessionInfo> filterSessions(
  List<CodeSessionInfo> sessions,
  String query, {
  Map<String, String> projectNames = const {},
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return sessions;
  bool has(String text) => text.toLowerCase().contains(q);
  return [
    for (final s in sessions)
      if (has(s.title) || has(s.branch) || has(projectNames[s.projectId] ?? '')) s,
  ];
}

/// The sidebar's Code lists: pinned sessions (newest first), then the rest in stored order. Subagents open from
/// their parent's transcript, so they are in neither.
({List<CodeSessionInfo> pinned, List<CodeSessionInfo> recent}) groupCodeSessions(List<CodeSessionInfo> sessions) {
  final own = [
    for (final s in sessions)
      if (!s.isSubagent) s,
  ];
  return (
    pinned: [
      for (final s in own)
        if (s.pinned) s,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
    recent: [
      for (final s in own)
        if (!s.pinned) s,
    ],
  );
}

/// Code mode: pinned sessions, then projects, each with its sessions (public for tests).
class CodeSessionList extends ConsumerWidget {
  const CodeSessionList({super.key, required this.location, required this.query, required this.onNavigate});

  final String location;
  final String query;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Host.isDesktop) return RemoteSessionList(location: location, onNavigate: onNavigate, dense: true);
    final theme = EveryTheme.of(context);
    final projects = ref.watch(codeProjectsProvider);
    final names = {for (final p in projects) p.id: p.name};
    // Sessions of a removed project are in no list, so Pinned, Recents and the empty-search check agree.
    final known = [
      for (final s in ref.watch(codeSessionsProvider))
        if (names.containsKey(s.projectId)) s,
    ];
    final groups = groupCodeSessions(filterSessions(known, query, projectNames: names));
    final searching = query.trim().isNotEmpty;
    final folded = ref.watch(sidebarFoldedProjectsProvider);
    final active = location.startsWith('/code/s/') ? location.substring('/code/s/'.length) : null;
    if (projects.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text('Open a project to start a session.', style: theme.type.callout.tint(theme.textMuted)),
      );
    }
    if (searching && groups.pinned.isEmpty && groups.recent.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text('No matching sessions.', style: theme.type.callout.tint(theme.textMuted)),
      );
    }
    Widget label(String text) => KitLabel(text, padding: const EdgeInsets.fromLTRB(20, 14, 20, 6));
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        if (groups.pinned.isNotEmpty) ...[
          label('Pinned'),
          for (final s in groups.pinned)
            SessionTile(
              info: s,
              dense: true,
              selected: s.id == active,
              caption: names[s.projectId],
              onOpen: () => onNavigate(Routes.codeSession(s.id)),
            ),
          if (groups.recent.isNotEmpty) label('Recent'),
        ],
        for (final p in projects)
          if (!searching || groups.recent.any((s) => s.projectId == p.id)) ...[
            _ProjectHeader(
              key: ValueKey('sidebar.project.${p.id}'),
              project: p,
              // A search shows every match, folded or not.
              open: searching || !folded.contains(p.id),
              onToggle: searching ? null : () => ref.read(sidebarFoldedProjectsProvider.notifier).toggle(p.id),
              onNewSession: () => onNavigate(Routes.newCodeSession(p.id)),
            ),
            AnimatedSize(
              duration: Motion.reduced(context) ? Duration.zero : Motion.move,
              curve: Motion.easeInOut,
              alignment: Alignment.topCenter,
              child: searching || !folded.contains(p.id)
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final s in groups.recent.where((s) => s.projectId == p.id))
                          SessionTile(
                            info: s,
                            dense: true,
                            selected: s.id == active,
                            onOpen: () => onNavigate(Routes.codeSession(s.id)),
                          ),
                      ],
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
      ],
    );
  }
}

/// A project's name in the Code list, with where it runs when that isn't this computer, and a ⋯ (on hover) to
/// change that or remove the project from the list.
class _ProjectHeader extends ConsumerStatefulWidget {
  const _ProjectHeader({
    super.key,
    required this.project,
    required this.open,
    required this.onNewSession,
    this.onToggle,
  });

  final CodeProject project;

  /// Whether its sessions show; [onToggle] folds or opens them (null while searching).
  final bool open;
  final VoidCallback? onToggle;

  /// Opens Code home with this project picked.
  final VoidCallback onNewSession;

  @override
  ConsumerState<_ProjectHeader> createState() => _ProjectHeaderState();
}

class _ProjectHeaderState extends ConsumerState<_ProjectHeader> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final p = widget.project;
    final env = watchEnvironment(ref, p.environment);
    // The id stands in while the list loads or when the environment is gone.
    final where = p.environment == 'host' ? null : env?.label ?? p.environment;
    final muted = _hover ? theme.textMuted : theme.textSubtle;
    // Like a Settings group heading: name over a hairline, a chevron that folds the project's sessions. The insets
    // match the session rows', so the ⋯ lines up with theirs.
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggle,
        child: Semantics(
          button: widget.onToggle != null,
          expanded: widget.open,
          label: p.name,
          child: Container(
            margin: const EdgeInsets.fromLTRB(8, 12, 8, 4),
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 5),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.border)),
            ),
            child: Row(
              children: [
                AdaptiveIcon(EveryIcon.projects, size: 13, color: muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          p.name,
                          overflow: TextOverflow.ellipsis,
                          style: theme.type.caption.medium.tint(muted),
                        ),
                      ),
                      if (where != null) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            where,
                            key: ValueKey('sidebar.project.${p.id}.environment'),
                            overflow: TextOverflow.ellipsis,
                            style: theme.type.caption.tint(theme.textSubtle),
                          ),
                        ),
                      ],
                      const SizedBox(width: 4),
                      AnimatedRotation(
                        turns: widget.open ? 0 : -0.25,
                        duration: Motion.reduced(context) ? Duration.zero : Motion.swap,
                        curve: Motion.easeInOut,
                        child: AdaptiveIcon(
                          EveryIcon.chevronDown,
                          key: ValueKey('sidebar.project.${p.id}.fold'),
                          size: 13,
                          color: muted,
                        ),
                      ),
                    ],
                  ),
                ),
                Opacity(
                  opacity: _hover || Host.isMobile ? 1 : 0,
                  child: AnchoredPopover(
                    width: 300,
                    builder: (context, close) =>
                        _ProjectOptions(project: p, close: close, onNewSession: widget.onNewSession),
                    child: Padding(
                      key: ValueKey('sidebar.project.${p.id}.options'),
                      padding: const EdgeInsets.only(left: 6),
                      child: AdaptiveIcon(EveryIcon.more, size: 14, color: theme.textMuted),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Projects whose sessions are folded in the Code sidebar, by id (Preferences `code.sidebar.folded`).
final sidebarFoldedProjectsProvider = NotifierProvider<SidebarFoldedProjects, Set<String>>(SidebarFoldedProjects.new);

final class SidebarFoldedProjects extends Notifier<Set<String>> {
  static const key = 'code.sidebar.folded';

  @override
  Set<String> build() {
    final raw = ref.read(preferencesProvider)[key];
    return raw == null || raw.isEmpty ? const {} : raw.split('\n').toSet();
  }

  void toggle(String id) {
    state = state.contains(id) ? ({...state}..remove(id)) : {...state, id};
    ref.read(preferencesProvider)[key] = state.join('\n');
  }
}

/// The ⋯ popover: Environment (opens the list in place), Remove from list.
class _ProjectOptions extends ConsumerStatefulWidget {
  final VoidCallback onNewSession;

  const _ProjectOptions({required this.project, required this.close, required this.onNewSession});

  final CodeProject project;
  final VoidCallback close;

  @override
  ConsumerState<_ProjectOptions> createState() => _ProjectOptionsState();
}

class _ProjectOptionsState extends ConsumerState<_ProjectOptions> {
  var _environment = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final p = widget.project;
    if (_environment) {
      return EnvironmentPanel(
        envId: p.environment,
        close: widget.close,
        onPick: (id) => ref.read(codeProjectsProvider.notifier).setEnvironment(p.id, id),
      );
    }
    final env = watchEnvironment(ref, p.environment);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PopoverRow(
            key: const ValueKey('sidebar.project.new-session'),
            leading: AdaptiveIcon(EveryIcon.add, size: 15, color: theme.textMuted),
            title: 'New session',
            subtitle: 'In ${p.name}',
            onTap: () {
              widget.close();
              widget.onNewSession();
            },
          ),
          PopoverRow(
            key: const ValueKey('sidebar.project.environment'),
            leading: AdaptiveIcon(EveryIcon.command, size: 15, color: theme.textMuted),
            title: 'Environment',
            subtitle: env?.label ?? (p.environment == 'host' ? EnvKind.host.label : p.environment),
            onTap: () => setState(() => _environment = true),
          ),
          PopoverRow(
            key: const ValueKey('sidebar.project.remove'),
            leading: AdaptiveIcon(EveryIcon.delete, size: 15, color: theme.danger),
            title: 'Remove from list',
            subtitle: 'The folder stays',
            destructive: true,
            onTap: () {
              widget.close();
              ref.read(codeProjectsProvider.notifier).remove(p.id);
            },
          ),
        ],
      ),
    );
  }
}

final class _Destination {
  const _Destination(this.icon, this.label, this.selected, this.route, {this.onTap, this.keys});

  final EveryIcon icon;
  final String label;
  final bool selected;
  final String? route;
  final VoidCallback? onTap;

  /// Its keyboard shortcut, shown at the row's end.
  final String? keys;
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.keys,
    this.touch = false,
  });

  final EveryIcon icon;
  final String label;
  final bool selected;
  final String? keys;
  final bool touch;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    selected: selected,
    excludeSemantics: true,
    button: true,
    child: MenuRow(
      onTap: onTap,
      selected: selected,
      touch: touch,
      leading: AdaptiveIcon(icon, size: touch ? 20 : 16),
      trailing: keys == null ? null : Kbd(keys!),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );
}

class _Recents extends ConsumerWidget {
  const _Recents({required this.location, required this.matches, required this.onNavigate});

  final String location;
  final Set<String>? matches;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final conversations = ref.watch(conversationsProvider);
    final activeId = location.startsWith('/chat/') ? location.substring(6) : null;
    final all = conversations.value ?? const <Conversation>[];
    final visible = matches == null ? all : all.where((c) => matches!.contains(c.id)).toList();
    final pinned = visible.where((c) => c.pinned).toList();
    final recent = visible.where((c) => !c.pinned).toList();

    if (conversations.isLoading && all.isEmpty) return const Center(child: AdaptiveProgress());
    if (visible.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(matches != null ? 'No matches' : 'No chats yet', style: theme.type.callout.tint(theme.textSubtle)),
      );
    }

    Widget label(String text) => KitLabel(text, padding: const EdgeInsets.fromLTRB(20, 14, 20, 6));

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        if (pinned.isNotEmpty) ...[
          label('Starred'),
          for (final (i, c) in pinned.indexed)
            ConversationTile(
              conversation: c,
              selected: c.id == activeId,
              onOpen: () => onNavigate(Routes.chat(c.id)),
            ).rowIn(i < 16 ? i : 16),
        ],
        if (recent.isNotEmpty) ...[
          label(matches == null ? 'Recent' : 'Results'),
          for (final (i, c) in recent.indexed)
            ConversationTile(
              conversation: c,
              selected: c.id == activeId,
              onOpen: () => onNavigate(Routes.chat(c.id)),
            ).rowIn(pinned.length + i < 16 ? pinned.length + i : 16),
        ],
      ],
    );
  }
}

/// One chat in a list, with a hover menu (star, rename, delete).
class ConversationTile extends ConsumerStatefulWidget {
  const ConversationTile({
    super.key,
    required this.conversation,
    required this.selected,
    required this.onOpen,
    this.subtitle,
  });

  final Conversation conversation;
  final bool selected;
  final VoidCallback onOpen;
  final String? subtitle;

  @override
  ConsumerState<ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends ConsumerState<ConversationTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final c = widget.conversation;
    final repo = ref.read(chatRepositoryProvider);
    final showMenu = _hover || widget.selected || Host.isMobile;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onOpen,
        child: Semantics(
          button: true,
          selected: widget.selected,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 0.5),
            padding: const EdgeInsets.fromLTRB(10, 0, 2, 0),
            constraints: BoxConstraints(minHeight: Host.isMobile ? 44 : 32),
            decoration: BoxDecoration(
              color: widget.selected || _hover ? theme.hover : null,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: (Host.isMobile ? theme.type.body : theme.type.callout).tint(
                          widget.selected ? theme.text : theme.textMuted,
                        ),
                      ),
                      if (widget.subtitle != null)
                        Text(widget.subtitle!, style: theme.type.caption.tint(theme.textMuted)),
                    ],
                  ),
                ),
                Opacity(
                  opacity: showMenu ? 1 : 0,
                  child: AdaptiveMenuButton(
                    tooltip: 'Chat options',
                    actions: [
                      MenuAction(
                        label: c.pinned ? 'Unstar' : 'Star',
                        icon: EveryIcon.pin,
                        onSelected: () => repo.setPinned(c.id, pinned: !c.pinned),
                      ),
                      MenuAction(label: 'Rename', icon: EveryIcon.edit, onSelected: () => _rename(repo)),
                      MenuAction(
                        label: 'Delete',
                        icon: EveryIcon.delete,
                        destructive: true,
                        onSelected: () => _confirmDelete(repo),
                      ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: AdaptiveIcon(EveryIcon.more, size: 14, color: theme.textMuted),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _rename(ChatRepository repo) async {
    final title = await showAdaptivePrompt(
      context,
      title: 'Rename chat',
      initialValue: widget.conversation.title,
      confirmLabel: 'Rename',
    );
    if (title != null && title.trim().isNotEmpty) await repo.rename(widget.conversation.id, title.trim());
  }

  Future<void> _confirmDelete(ChatRepository repo) async {
    final confirmed = await showAdaptiveConfirm(
      context,
      title: 'Delete chat?',
      message: '"${widget.conversation.title}" will be permanently deleted from this device.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed) await repo.delete(widget.conversation.id);
  }
}
