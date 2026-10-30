import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../chat/chat_providers.dart';
import '../../chat/data/chat_repository.dart';
import '../../chat/domain/message.dart';
import '../domain/date_buckets.dart';

/// Sidebar: new chat, search, conversations grouped by recency, and app destinations.
class HistoryPane extends ConsumerStatefulWidget {
  const HistoryPane({super.key, required this.location, required this.onNavigate});

  final String location;
  final ValueChanged<String> onNavigate;

  @override
  ConsumerState<HistoryPane> createState() => _HistoryPaneState();
}

class _HistoryPaneState extends ConsumerState<HistoryPane> {
  final _search = TextEditingController();
  Timer? _debounce;

  /// Null when not searching; otherwise the matching conversation ids.
  Set<String>? _matches;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onQuery(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () async {
      if (query.trim().isEmpty) {
        setState(() => _matches = null);
        return;
      }
      final ids = await ref.read(chatRepositoryProvider).search(query);
      final lower = query.toLowerCase();
      // Titles match too, not just message bodies.
      final titles = ref.read(conversationsProvider).value ?? const [];
      if (!mounted) return;
      setState(
        () => _matches = {
          ...ids,
          for (final c in titles)
            if (c.title.toLowerCase().contains(lower)) c.id,
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final conversations = ref.watch(conversationsProvider);
    final activeId = widget.location.startsWith('/chat/') ? widget.location.substring(6) : null;

    final visible = switch (conversations.value) {
      null => const <Conversation>[],
      final list when _matches == null => list,
      final list => list.where((c) => _matches!.contains(c.id)).toList(),
    };
    final groups = groupByRecency(visible, now: DateTime.now());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          // macOS: the header sits in the title-bar row, clear of the traffic lights.
          height: theme.design == DesignLanguage.macos ? 52 : null,
          padding: theme.design == DesignLanguage.macos
              ? const EdgeInsets.only(left: 92, right: 8)
              : const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'EveryAI',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.text,
                    fontSize: theme.design == DesignLanguage.macos ? 13 : 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              AdaptiveIconButton(
                icon: EveryIcon.newChat,
                tooltip: 'New chat',
                onPressed: () => widget.onNavigate(Routes.newChat),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: AdaptiveTextField(
            controller: _search,
            placeholder: 'Search chats',
            prefix: AdaptiveIcon(EveryIcon.search, size: 16, color: theme.textMuted),
            onChanged: _onQuery,
            textInputAction: TextInputAction.search,
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: conversations.isLoading && visible.isEmpty
              ? const Center(child: AdaptiveProgress())
              : visible.isEmpty
              ? _EmptyHistory(searching: _matches != null)
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  itemCount: groups.length,
                  itemBuilder: (context, i) {
                    final (bucket, items) = groups[i];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AdaptiveSectionHeader(bucket.label),
                        for (final c in items)
                          _ConversationTile(
                            conversation: c,
                            selected: c.id == activeId,
                            onOpen: () => widget.onNavigate(Routes.chat(c.id)),
                          ),
                      ],
                    );
                  },
                ),
        ),
        Container(height: 1, color: theme.border),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AdaptiveListTile(
                dense: true,
                leading: AdaptiveIcon(EveryIcon.models, size: 18, color: theme.textMuted),
                title: const Text('Models'),
                selected: widget.location == Routes.models,
                onTap: () => widget.onNavigate(Routes.models),
              ),
              AdaptiveListTile(
                dense: true,
                leading: AdaptiveIcon(EveryIcon.settings, size: 18, color: theme.textMuted),
                title: const Text('Settings'),
                selected: widget.location == Routes.settings,
                onTap: () => widget.onNavigate(Routes.settings),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ConversationTile extends ConsumerWidget {
  const _ConversationTile({required this.conversation, required this.selected, required this.onOpen});

  final Conversation conversation;
  final bool selected;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final repo = ref.read(chatRepositoryProvider);
    return AdaptiveListTile(
      dense: true,
      selected: selected,
      title: Text(conversation.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: onOpen,
      trailing: AdaptiveMenuButton(
        tooltip: 'Chat options',
        actions: [
          MenuAction(
            label: conversation.pinned ? 'Unpin' : 'Pin',
            icon: EveryIcon.pin,
            onSelected: () => repo.setPinned(conversation.id, pinned: !conversation.pinned),
          ),
          MenuAction(
            label: 'Delete',
            icon: EveryIcon.delete,
            destructive: true,
            onSelected: () => _confirmDelete(context, repo),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: AdaptiveIcon(conversation.pinned ? EveryIcon.pin : EveryIcon.more, size: 14, color: theme.textMuted),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, ChatRepository repo) async {
    final confirmed = await showAdaptiveConfirm(
      context,
      title: 'Delete chat?',
      message: '"${conversation.title}" will be permanently deleted from this device.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed) await repo.delete(conversation.id);
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory({required this.searching});

  final bool searching;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          searching ? 'No chats match.' : 'Your chats will appear here.',
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.textMuted, fontSize: 13),
        ),
      ),
    );
  }
}
