import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/brand.dart';
import '../../harness/events.dart';

/// "Model overloaded — retrying in 8s · attempt 3 of 8", counting down in
/// place, with Retry now and Stop. Shown while a model call is retried; gone
/// once the reply streams.
class RetryRow extends StatefulWidget {
  const RetryRow({super.key, required this.retry, this.onRetryNow, this.onStop});

  final RetryState retry;
  final VoidCallback? onRetryNow;
  final VoidCallback? onStop;

  @override
  State<RetryRow> createState() => _RetryRowState();
}

class _RetryRowState extends State<RetryRow> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final r = widget.retry;
    final left = r.until.difference(DateTime.now());
    final seconds = (left.inMilliseconds / 1000).ceil();
    final when = seconds > 0 ? 'retrying in ${_duration(seconds)}' : 'retrying now';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: theme.warning.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
      child: Row(
        children: [
          const EveryMarkActivity(activity: MarkActivity.thinking, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${retryHeadline(r)} — $when', style: theme.type.callout.tint(theme.text)),
                  TextSpan(
                    text: ' · attempt ${r.attempt} of ${r.max}',
                    style: theme.type.callout.tint(theme.textMuted),
                  ),
                ],
              ),
            ),
          ),
          if (widget.onRetryNow != null && seconds > 0) ...[
            const SizedBox(width: 8),
            AdaptiveButton(label: 'Retry now', emphasis: ButtonEmphasis.secondary, onPressed: widget.onRetryNow),
          ],
          if (widget.onStop != null) ...[
            const SizedBox(width: 8),
            AdaptiveButton(label: 'Stop', emphasis: ButtonEmphasis.secondary, onPressed: widget.onStop),
          ],
        ],
      ),
    );
  }

  static String _duration(int seconds) => seconds < 60 ? '${seconds}s' : '${seconds ~/ 60}m ${seconds % 60}s';
}

/// What went wrong, in a few words.
String retryHeadline(RetryState r) => switch (r.status) {
  529 || 503 => 'Model overloaded',
  429 => 'Rate limited',
  408 || 504 => 'Model timed out',
  final s? when s >= 500 => 'Model server error',
  _ when r.reason.toLowerCase().contains('overload') => 'Model overloaded',
  _ when r.reason.toLowerCase().contains('rate') => 'Rate limited',
  _ => 'Connection to the model dropped',
};
