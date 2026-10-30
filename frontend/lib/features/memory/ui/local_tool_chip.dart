import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../chat/domain/message.dart';
import '../memory_providers.dart';

/// What a `memory` or `search_chats` call did, for the one-line chip:
/// (label, detail, failed).
({String label, String detail, bool failed}) describeLocalCall(ToolCallPart part) {
  final args = switch (_decode(part.argumentsJson)) {
    final Map<String, Object?> m => m,
    _ => const <String, Object?>{},
  };
  final result = switch (_decode(part.resultJson)) {
    final Map<String, Object?> m => m,
    _ => null,
  };
  final failed = result?['error'] == true;
  final pending = result == null;
  String str(String k) => (args[k] as String? ?? '').trim();
  if (part.toolName == searchChatsTool) {
    final chat = str('chat_id');
    if (chat.isNotEmpty) {
      return (label: pending ? 'Reading an earlier chat…' : 'Read an earlier chat', detail: '', failed: failed);
    }
    return (label: pending ? 'Searching your chats…' : 'Searched your chats', detail: str('query'), failed: failed);
  }
  final where = args['target'] == 'notes' ? 'its notes' : 'memory';
  final label = switch ((args['action'], failed)) {
    (_, true) => "Couldn't update $where",
    ('remove', _) => 'Removed from $where',
    ('replace', _) => 'Updated $where',
    _ => 'Saved to $where',
  };
  return (
    label: pending ? '$label…' : label,
    detail: args['action'] == 'remove' ? str('old_text') : str('text'),
    failed: failed,
  );
}

Object? _decode(String? json) {
  if (json == null) return null;
  try {
    return jsonDecode(json);
  } on FormatException {
    return null;
  }
}

/// A memory edit or chat search in the transcript: one muted line that opens
/// Settings → Memory.
class LocalToolChip extends StatelessWidget {
  const LocalToolChip({super.key, required this.part});

  final ToolCallPart part;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final (:label, :detail, :failed) = describeLocalCall(part);
    final color = failed ? theme.danger : theme.textMuted;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          AdaptiveIcon(part.toolName == searchChatsTool ? EveryIcon.search : EveryIcon.spark, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (detail.isNotEmpty) TextSpan(text: '  $detail'),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 13),
            ),
          ),
        ],
      ),
    );
    if (part.toolName != memoryTool) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.go(Routes.memory),
      child: MouseRegion(cursor: SystemMouseCursors.click, child: row),
    );
  }
}
