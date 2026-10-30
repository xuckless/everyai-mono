import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../auth/auth_providers.dart';
import '../../auth/domain/auth_state.dart';
import '../../chat/chat_providers.dart';
import '../../chat/data/chat_repository.dart';
import '../../chat/domain/message.dart';

/// Width of the collapsed rail. macOS needs room for the traffic lights above it.
double sidebarRailWidth(DesignLanguage design) => design == DesignLanguage.macos ? 92 : 60;

/// The app sidebar, Claude-desktop style. Expanded: destinations, then recent
/// chats, then the account. Collapsed: an icon rail with the same destinations.
class Sidebar extends ConsumerStatefulWidget {
  const Sidebar({
    super.key,
    required this.location,
    required this.collapsed,
    required this.onNavigate,
    required this.onToggle,
  });

  final String location;
  final bool collapsed;
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
    if (widget.collapsed) widget.onToggle();
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  void _closeSearch() {
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _searching = false;
      _matches = null;
    });
  }

  void _onQuery(String query) {
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
    final macos = theme.design == DesignLanguage.macos;
    final collapsed = widget.collapsed;
    final loc = widget.location;

    final destinations = <_Destination>[
      _Destination(
        EveryIcon.newChat,
        'New chat',
        loc.startsWith('/chat/') && _isBlankChat(loc),
        Routes.newChat,
        accent: true,
      ),
      _Destination(EveryIcon.search, 'Search', _searching, null, onTap: _searching ? _closeSearch : _openSearch),
      _Destination(EveryIcon.chat, 'Chats', loc == Routes.chats, Routes.chats),
      _Destination(EveryIcon.projects, 'Projects', loc == Routes.projects, Routes.projects),
      _Destination(EveryIcon.artifacts, 'Artifacts', loc == Routes.artifacts, Routes.artifacts),
      _Destination(EveryIcon.models, 'Models', loc == Routes.models, Routes.models),
    ];

    final header = SizedBox(
      // macOS: the title-bar row, clear of the traffic lights.
      height: macos ? 52 : 56,
      child: collapsed
          ? (macos ? null : Center(child: _toggleButton()))
          : Padding(
              padding: EdgeInsets.only(left: macos ? 92 : 16, right: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'EveryAI',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.text,
                        fontSize: macos ? 14 : 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                  _toggleButton(),
                ],
              ),
            ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (collapsed && macos) Center(child: _toggleButton()),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : 8, vertical: 2),
          child: Column(
            crossAxisAlignment: collapsed ? CrossAxisAlignment.center : CrossAxisAlignment.stretch,
            children: [
              for (final d in destinations)
                _NavItem(
                  icon: d.icon,
                  label: d.label,
                  selected: d.selected,
                  accent: d.accent,
                  collapsed: collapsed,
                  onTap: d.onTap ?? () => widget.onNavigate(d.route!),
                ),
            ],
          ),
        ),
        if (!collapsed && _searching)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            child: CallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.escape): _closeSearch},
              child: AdaptiveTextField(
                controller: _search,
                focusNode: _searchFocus,
                placeholder: 'Search chats',
                prefix: AdaptiveIcon(EveryIcon.search, size: 15, color: theme.textMuted),
                onChanged: _onQuery,
                textInputAction: TextInputAction.search,
              ),
            ),
          ),
        Expanded(
          child: collapsed
              ? const SizedBox.shrink()
              : _Recents(location: loc, matches: _matches, onNavigate: widget.onNavigate),
        ),
        Container(height: 1, color: theme.border),
        _AccountRow(
          collapsed: collapsed,
          selected: loc == Routes.settings,
          onTap: () => widget.onNavigate(Routes.settings),
        ),
      ],
    );
  }

  Widget _toggleButton() => AdaptiveIconButton(
    icon: EveryIcon.sidebar,
    tooltip: widget.collapsed ? 'Expand sidebar' : 'Collapse sidebar',
    onPressed: widget.onToggle,
  );

  /// The current chat is "new" when it has no stored conversation yet.
  bool _isBlankChat(String location) {
    final id = location.substring('/chat/'.length);
    final all = ref.watch(conversationsProvider).value;
    return all != null && !all.any((c) => c.id == id);
  }
}

final class _Destination {
  const _Destination(this.icon, this.label, this.selected, this.route, {this.onTap, this.accent = false});

  final EveryIcon icon;
  final String label;
  final bool selected;
  final String? route;
  final VoidCallback? onTap;
  final bool accent;
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.collapsed,
    required this.onTap,
    this.accent = false,
  });

  final EveryIcon icon;
  final String label;
  final bool selected;
  final bool collapsed;
  final bool accent;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final fill = widget.selected
        ? theme.text.withValues(alpha: 0.09)
        : _hover
        ? theme.text.withValues(alpha: 0.05)
        : null;
    final icon = widget.accent
        ? Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(color: theme.accent, shape: BoxShape.circle),
            child: Center(child: AdaptiveIcon(EveryIcon.add, size: 15, color: theme.onAccent)),
          )
        : SizedBox(
            width: 24,
            child: Center(child: AdaptiveIcon(widget.icon, size: 18, color: theme.text.withValues(alpha: 0.85))),
          );
    final content = widget.collapsed
        ? SizedBox(width: 40, height: 36, child: Center(child: icon))
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                icon,
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: widget.accent ? theme.accent : theme.text,
                      fontSize: 14,
                      fontWeight: widget.accent || widget.selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          );
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(8)),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
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
        child: Text(
          matches != null ? 'No chats match.' : 'Your chats will appear here.',
          style: TextStyle(color: theme.textMuted, fontSize: 13),
        ),
      );
    }

    Widget label(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(
        text,
        style: TextStyle(color: theme.textMuted, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        if (pinned.isNotEmpty) ...[
          label('Starred'),
          for (final c in pinned)
            ConversationTile(conversation: c, selected: c.id == activeId, onOpen: () => onNavigate(Routes.chat(c.id))),
        ],
        if (recent.isNotEmpty) ...[
          label(matches == null ? 'Recents' : 'Results'),
          for (final c in recent)
            ConversationTile(conversation: c, selected: c.id == activeId, onOpen: () => onNavigate(Routes.chat(c.id))),
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
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
            constraints: const BoxConstraints(minHeight: 34),
            decoration: BoxDecoration(
              color: widget.selected
                  ? theme.text.withValues(alpha: 0.09)
                  : _hover
                  ? theme.text.withValues(alpha: 0.05)
                  : null,
              borderRadius: BorderRadius.circular(8),
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
                        style: TextStyle(color: theme.text, fontSize: 13.5),
                      ),
                      if (widget.subtitle != null)
                        Text(widget.subtitle!, style: TextStyle(color: theme.textMuted, fontSize: 12)),
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

class _AccountRow extends ConsumerWidget {
  const _AccountRow({required this.collapsed, required this.selected, required this.onTap});

  final bool collapsed;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final (name, plan) = switch (ref.watch(authProvider)) {
      Bypassed() => ('Guest', 'Developer mode'),
      SignedIn() => ('Account', 'Free plan'),
      _ => ('Signed out', ''),
    };
    final avatar = Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(color: theme.accent.withValues(alpha: 0.25), shape: BoxShape.circle),
      child: Center(
        child: Text(
          name[0],
          style: TextStyle(color: theme.text, fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
    );
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Semantics(
          button: true,
          label: 'Settings',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: selected ? theme.text.withValues(alpha: 0.09) : null,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: collapsed
                    ? Center(child: avatar)
                    : Row(
                        children: [
                          avatar,
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  name,
                                  style: TextStyle(color: theme.text, fontSize: 13.5, fontWeight: FontWeight.w600),
                                ),
                                if (plan.isNotEmpty) Text(plan, style: TextStyle(color: theme.textMuted, fontSize: 12)),
                              ],
                            ),
                          ),
                          AdaptiveIcon(EveryIcon.settings, size: 17, color: theme.textMuted),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
