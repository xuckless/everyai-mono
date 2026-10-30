import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../models/domain/model_catalog.dart';
import '../attachment.dart';

/// The composer's pending attachments. With a [model], files it can't read are
/// dimmed with the reason, and [suggestion] (a model that reads them all) is
/// offered through [onSwitchModel].
class AttachmentTray extends StatelessWidget {
  const AttachmentTray({
    super.key,
    required this.attachments,
    required this.onRemove,
    this.model,
    this.suggestion,
    this.onSwitchModel,
    this.note,
  });

  final List<Attachment> attachments;
  final ValueChanged<Attachment> onRemove;
  final ModelSpec? model;
  final ModelSpec? suggestion;
  final ValueChanged<ModelSpec>? onSwitchModel;

  /// A line under the chips (Code: "Saved to .everyai/uploads").
  final String? note;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    final theme = EveryTheme.of(context);
    final m = model;
    final blocked = m == null ? const <Attachment>[] : attachments.where((a) => a.unsupportedBy(m) != null).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in attachments)
                AttachmentChip(
                  name: a.name,
                  kind: a.kind,
                  size: a.size,
                  bytes: a.kind == AttachmentKind.image ? a.bytes : null,
                  dimmed: blocked.contains(a),
                  onRemove: () => onRemove(a),
                ),
            ],
          ),
          if (blocked.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Flexible(
                  child: Text(
                    '${blocked.first.unsupportedBy(m!)}. Remove ${blocked.length == 1 ? 'it' : 'them'}'
                    '${suggestion == null ? '' : ' or switch models'} to send.',
                    style: TextStyle(color: theme.warning, fontSize: 12.5),
                  ),
                ),
                if (suggestion case final s? when onSwitchModel != null) ...[
                  const SizedBox(width: 8),
                  AdaptiveButton(
                    label: 'Switch to ${s.name}',
                    emphasis: ButtonEmphasis.secondary,
                    onPressed: () => onSwitchModel!(s),
                  ),
                ],
              ],
            ),
          ] else if (note != null) ...[
            const SizedBox(height: 6),
            Text(note!, style: TextStyle(color: theme.textMuted, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

/// One file: a thumbnail for images, else an icon, name and size.
class AttachmentChip extends StatelessWidget {
  const AttachmentChip({
    super.key,
    required this.name,
    required this.kind,
    this.size,
    this.bytes,
    this.dimmed = false,
    this.onRemove,
    this.onTap,
  });

  final String name;
  final AttachmentKind kind;
  final int? size;

  /// Image bytes, for the thumbnail.
  final Uint8List? bytes;
  final bool dimmed;
  final VoidCallback? onRemove;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final image = bytes;
    final Widget body;
    if (image != null) {
      body = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(
          image,
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          semanticLabel: name,
          errorBuilder: (_, _, _) => SizedBox.square(dimension: 56, child: Center(child: Text(name))),
        ),
      );
    } else {
      body = Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
        decoration: BoxDecoration(
          color: theme.surfaceRaised,
          border: Border.all(color: theme.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AdaptiveIcon(
              switch (kind) {
                AttachmentKind.text => EveryIcon.code,
                AttachmentKind.pdf => EveryIcon.document,
                _ => EveryIcon.attach,
              },
              size: 16,
              color: theme.textMuted,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: theme.text, fontSize: 12.5, fontWeight: FontWeight.w500),
                  ),
                  Text(
                    [kind.label, if (size != null) formatBytes(size!)].join(' · '),
                    style: TextStyle(color: theme.textMuted, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    Widget chip = Opacity(opacity: dimmed ? 0.45 : 1, child: body);
    if (onTap != null) chip = GestureDetector(onTap: onTap, child: chip);
    if (onRemove == null) return Semantics(label: name, child: chip);
    return Semantics(
      label: name,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          chip,
          Positioned(
            top: -6,
            right: -6,
            child: GestureDetector(
              onTap: onRemove,
              child: Semantics(
                button: true,
                label: 'Remove $name',
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: theme.text,
                    shape: BoxShape.circle,
                    border: Border.all(color: theme.surface, width: 1.5),
                  ),
                  child: Center(child: AdaptiveIcon(EveryIcon.close, size: 10, color: theme.surface)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
