import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../../core/motion/motion.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../chat/domain/message.dart';

/// Where a `look` call stands, read from what the chat recorded on it.
sealed class LookOutcome {
  const LookOutcome(this.id);

  /// What it looked at.
  final String id;

  static LookOutcome of(ToolCallPart part) {
    final args = _map(part.argumentsJson);
    final id = args['id'] as String? ?? '';
    final result = part.resultJson;
    if (result == null) return LookRunning(id);
    final r = _map(result);
    if (r['error'] case final String error) return LookFailed(id, error);
    return LookDone(
      id,
      findings: [for (final f in (r['findings'] as List<Object?>?) ?? const []) '$f'],
      pictures: [
        for (final p in (r['pictures'] as List<Object?>?) ?? const [])
          if (p is String) base64Decode(p),
      ],
    );
  }
}

/// The app is drawing it.
final class LookRunning extends LookOutcome {
  const LookRunning(super.id);
}

/// It couldn't be drawn ([reason] is what the model was told).
final class LookFailed extends LookOutcome {
  const LookFailed(super.id, this.reason);
  final String reason;
}

/// Drawn and checked: what the checks found, and small copies of what the model saw.
final class LookDone extends LookOutcome {
  const LookDone(super.id, {required this.findings, required this.pictures});
  final List<String> findings;
  final List<Uint8List> pictures;
}

Map<String, Object?> _map(String json) {
  try {
    return switch (jsonDecode(json)) {
      final Map<String, Object?> m => m,
      _ => const {},
    };
  } on FormatException {
    return const {};
  }
}

/// A `look` call in the chat: one quiet row ("Checked fig-sun · 2 to fix") that opens to the pictures the model
/// saw and what the checks found. The final figure is its own card; this only says it was checked.
class LookRow extends StatefulWidget {
  const LookRow({super.key, required this.part});

  final ToolCallPart part;

  @override
  State<LookRow> createState() => _LookRowState();
}

class _LookRowState extends State<LookRow> {
  /// Whether the row is open (a disclosure, not a lifecycle).
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final outcome = LookOutcome.of(widget.part);
    final name = outcome.id.isEmpty ? 'the figure' : outcome.id;
    final (label, detail, color) = switch (outcome) {
      LookRunning() => ('Checking $name', '', theme.textMuted),
      LookFailed() => ('Could not check $name', '', theme.danger),
      LookDone(:final findings) when findings.isEmpty => ('Checked $name', 'looks right', theme.textMuted),
      LookDone(:final findings) => ('Checked $name', '${findings.length} to fix', theme.textMuted),
    };
    final canOpen = outcome is LookDone && (outcome.findings.isNotEmpty || outcome.pictures.isNotEmpty);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          AdaptiveIcon(EveryIcon.eye, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: outcome is LookRunning
                ? ShimmerText(label, style: theme.type.callout)
                : Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: label,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        if (detail.isNotEmpty) TextSpan(text: ' · $detail'),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.type.callout.tint(color),
                  ),
          ),
          if (canOpen) ...[
            const SizedBox(width: 4),
            AnimatedRotation(
              turns: _open ? 0.25 : 0,
              duration: Motion.swap,
              child: AdaptiveIcon(EveryIcon.chevronRight, size: 12, color: theme.textSubtle),
            ),
          ],
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (canOpen)
          Pressable(
            onTap: () => setState(() => _open = !_open),
            semanticLabel: '$label${detail.isEmpty ? '' : ', $detail'}',
            builder: (context, s, child) => child,
            child: row,
          )
        else
          row,
        AnimatedSize(
          duration: Motion.move,
          curve: Motion.easeInOut,
          alignment: Alignment.topLeft,
          child: !_open || outcome is! LookDone
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(left: 20, top: 4, bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (outcome.pictures.isNotEmpty)
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final p in outcome.pictures)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: DecoratedBox(
                                  position: DecorationPosition.foreground,
                                  decoration: BoxDecoration(
                                    border: Border.all(color: theme.border),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Image.memory(p, height: 120, fit: BoxFit.contain),
                                ),
                              ),
                          ],
                        ),
                      for (final f in outcome.findings)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text('· $f', style: theme.type.footnote.tint(theme.textMuted)),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
