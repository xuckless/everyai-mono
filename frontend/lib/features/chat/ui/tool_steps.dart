import 'package:flutter/widgets.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/brand.dart';
import '../../../core/ui/every_icons.dart';
import '../data/chat_transport.dart' show ToolRunStatus;
import '../domain/chat_session.dart';

/// What a server tool is doing or did: "Reading", "Read", "Couldn't read".
String toolStepLabel(String name, ToolRunStatus status) => switch ((name, status)) {
  ('web_fetch', ToolRunStatus.running) => 'Reading',
  ('web_fetch', ToolRunStatus.done) => 'Read',
  ('web_fetch', ToolRunStatus.failed) => 'Couldn\'t read',
  ('generate_image', ToolRunStatus.running) => 'Creating an image',
  ('generate_image', ToolRunStatus.done) => 'Created an image',
  ('generate_image', ToolRunStatus.failed) => 'Couldn\'t create the image',
  (_, ToolRunStatus.running) => 'Using ${_readable(name)}',
  (_, ToolRunStatus.done) => 'Used ${_readable(name)}',
  (_, ToolRunStatus.failed) => '${_readable(name)} failed',
};

String _readable(String name) => name.replaceAll('_', ' ');

/// "Read 3 pages, created 1 image" for finished steps.
String toolRunSummary(List<LiveToolStep> steps) {
  final pages = steps.where((s) => s.name == 'web_fetch').length;
  final images = steps.where((s) => s.name == 'generate_image').length;
  final other = steps.length - pages - images;
  String n(int count, String one, String many) => '$count ${count == 1 ? one : many}';
  final parts = [
    if (pages > 0) 'read ${n(pages, 'page', 'pages')}',
    if (images > 0) 'created ${n(images, 'image', 'images')}',
    if (other > 0) 'used ${n(other, 'tool', 'tools')}',
  ];
  final text = parts.join(', ');
  return text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
}

/// The preview for a step's detail: a URL as host plus a dimmed path, or the
/// text as is.
TextSpan toolDetailSpan(String detail, {required TextStyle base, required Color muted}) {
  final uri = Uri.tryParse(detail);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return TextSpan(text: detail, style: base);
  final rest = detail.substring(detail.indexOf(uri.host) + uri.host.length);
  return TextSpan(
    style: base,
    children: [
      TextSpan(text: uri.host),
      if (rest.isNotEmpty && rest != '/')
        TextSpan(
          text: rest,
          style: TextStyle(color: muted),
        ),
    ],
  );
}

/// The server tools of the turn in flight. Running steps get their own row
/// with the working mark; two or more finished ones fold into one summary
/// row that opens to each.
class LiveToolSteps extends StatefulWidget {
  const LiveToolSteps({super.key, required this.steps});
  final List<LiveToolStep> steps;

  @override
  State<LiveToolSteps> createState() => _LiveToolStepsState();
}

class _LiveToolStepsState extends State<LiveToolSteps> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final finished = widget.steps.where((s) => !s.running).toList();
    final running = widget.steps.where((s) => s.running);
    final fold = finished.length >= 2;
    final failed = finished.where((s) => s.status == ToolRunStatus.failed).length;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (fold)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _open = !_open),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Semantics(
                  button: true,
                  expanded: _open,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        AdaptiveIcon(
                          failed > 0 ? EveryIcon.close : EveryIcon.check,
                          size: 13,
                          color: failed > 0 ? theme.danger : theme.success,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '${toolRunSummary(finished)}${failed > 0 ? ' · $failed failed' : ''}',
                            overflow: TextOverflow.ellipsis,
                            style: theme.type.callout.tint(theme.textMuted),
                          ),
                        ),
                        const SizedBox(width: 4),
                        AnimatedRotation(
                          turns: _open ? 0.25 : 0,
                          duration: const Duration(milliseconds: 120),
                          child: AdaptiveIcon(EveryIcon.chevronRight, size: 11, color: theme.textMuted),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (!fold || _open)
            for (final s in finished)
              Padding(
                padding: EdgeInsets.only(left: fold ? 21 : 0),
                child: ToolStepRow(step: s),
              ),
          for (final s in running) ToolStepRow(step: s),
        ],
      ),
    );
  }
}

/// One server tool: the mark while it works, then a check or a cross; its
/// label; and a preview of what it works on.
class ToolStepRow extends StatelessWidget {
  const ToolStepRow({super.key, required this.step});
  final LiveToolStep step;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final detail = step.detail?.trim() ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          switch (step.status) {
            ToolRunStatus.running => const EveryMarkActivity(activity: MarkActivity.tool, size: 14),
            ToolRunStatus.done => AdaptiveIcon(EveryIcon.check, size: 13, color: theme.success),
            ToolRunStatus.failed => AdaptiveIcon(EveryIcon.close, size: 13, color: theme.danger),
          },
          const SizedBox(width: 8),
          Text(
            '${toolStepLabel(step.name, step.status)}${step.running && detail.isEmpty ? '…' : ''}',
            style: theme.type.callout.tint(theme.textMuted),
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text.rich(
                toolDetailSpan(
                  detail,
                  base: theme.type.caption.mono.tint(theme.text).copyWith(height: 1.4),
                  muted: theme.textMuted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
