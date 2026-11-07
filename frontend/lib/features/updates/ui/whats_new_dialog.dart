import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/motion/motion.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../domain/whats_new.dart';
import '../whats_new_providers.dart';

/// Shows [note] as the kit's modal. Long notes scroll inside it; lines wrap at a reading width.
Future<void> showWhatsNew(BuildContext context, ReleaseNote note) => showKitDialog<void>(
  context,
  builder: (ctx) => KitDialog(
    key: const ValueKey('whats-new'),
    title: "What's new",
    width: 520,
    body: WhatsNewBody(note),
    actions: [KitButton(key: const ValueKey('whats-new.close'), label: 'Continue', onPressed: Navigator.of(ctx).pop)],
  ),
);

/// After an update, this build's notes once (marked seen as they open, so a crash or quit doesn't repeat them).
void showWhatsNewOnce(BuildContext context, WidgetRef ref) {
  final note = ref.read(whatsNewProvider);
  if (note == null) return;
  ref.read(whatsNewProvider.notifier).markSeen();
  showWhatsNew(context, note);
}

/// The version line, the release's title, then each change: a headline and the sentence or two under it.
class WhatsNewBody extends StatelessWidget {
  const WhatsNewBody(this.note, {super.key});

  final ReleaseNote note;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final meta = [note.version, ?note.date].join('  ·  ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(meta, style: theme.type.caption.mono.tint(theme.textSubtle)),
        if (note.title case final t?) ...[
          const SizedBox(height: 6),
          Text(t, style: theme.type.body.medium.tint(theme.text)),
        ],
        const SizedBox(height: 16),
        for (final (i, item) in note.items.indexed) ...[
          if (i > 0) const SizedBox(height: 14),
          _Item(item).rowIn(i, base: const Duration(milliseconds: 80)),
        ],
        const SizedBox(height: 4),
      ],
    );
  }
}

class _Item extends StatelessWidget {
  const _Item(this.item);

  final WhatsNewItem item;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final headline = theme.type.callout.medium.tint(theme.text);
    // The dot sits on the headline's first line, whatever the text scale.
    final lineHeight = MediaQuery.textScalerOf(context).scale(headline.fontSize ?? 14) * (headline.height ?? 1.3);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(top: (lineHeight - 5) / 2),
          child: Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: theme.accent, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.headline, style: headline),
              if (item.body case final b? when b.trim().isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(b.trim(), style: theme.type.callout.copyWith(height: 1.5).tint(theme.textMuted)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
