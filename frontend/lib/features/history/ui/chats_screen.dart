import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/every_icons.dart';
import '../../chat/chat_providers.dart';
import '../../chat/domain/message.dart';
import '../domain/date_buckets.dart';
import 'sidebar.dart';

/// "Chats": every conversation, searchable, grouped by recency.
class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen> {
  final _query = TextEditingController();
  Set<String>? _matches;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _matches = null);
      return;
    }
    final ids = await ref.read(chatRepositoryProvider).search(query);
    final lower = query.toLowerCase();
    final all = ref.read(conversationsProvider).value ?? const <Conversation>[];
    if (!mounted) return;
    setState(
      () => _matches = {
        ...ids,
        for (final c in all)
          if (c.title.toLowerCase().contains(lower)) c.id,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final all = ref.watch(conversationsProvider).value ?? const <Conversation>[];
    final visible = _matches == null ? all : all.where((c) => _matches!.contains(c.id)).toList();
    final groups = groupByRecency(visible, now: DateTime.now());

    return AdaptivePage(
      title: 'Chats',
      actions: [
        AdaptiveIconButton(icon: EveryIcon.newChat, tooltip: 'New chat', onPressed: () => context.go(Routes.newChat)),
      ],
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: AdaptiveTextField(
                  controller: _query,
                  placeholder: 'Search your chats…',
                  prefix: AdaptiveIcon(EveryIcon.search, size: 16, color: theme.textMuted),
                  onChanged: _search,
                  textInputAction: TextInputAction.search,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                child: Text(
                  '${visible.length} chat${visible.length == 1 ? '' : 's'}',
                  style: TextStyle(color: theme.textMuted, fontSize: 12.5),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    for (final (bucket, items) in groups) ...[
                      AdaptiveSectionHeader(bucket.label),
                      for (final c in items)
                        ConversationTile(
                          conversation: c,
                          selected: false,
                          subtitle: _subtitle(c),
                          onOpen: () => context.go(Routes.chat(c.id)),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _subtitle(Conversation c) {
    final ago = DateTime.now().difference(c.updatedAt);
    return switch (ago) {
      < const Duration(minutes: 1) => 'Just now',
      < const Duration(hours: 1) => '${ago.inMinutes} min ago',
      < const Duration(days: 1) => '${ago.inHours} h ago',
      _ => '${ago.inDays} d ago',
    };
  }
}
