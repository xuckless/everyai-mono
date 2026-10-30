import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import 'attachment.dart';

/// Opens the system file picker. With [allowed], only those kinds can be
/// picked (the rest are greyed out in the native dialog); text and code are
/// always allowed. Without it, any file.
Future<List<XFile>> pickAttachmentFiles({Set<AttachmentKind>? allowed}) {
  if (allowed == null) return openFiles();
  return openFiles(
    acceptedTypeGroups: [
      const XTypeGroup(label: 'Text and code', extensions: textExtensions, uniformTypeIdentifiers: ['public.text']),
      if (allowed.contains(AttachmentKind.image))
        const XTypeGroup(label: 'Images', extensions: imageExtensions, uniformTypeIdentifiers: ['public.image']),
      if (allowed.contains(AttachmentKind.pdf))
        const XTypeGroup(label: 'PDFs', extensions: pdfExtensions, uniformTypeIdentifiers: ['com.adobe.pdf']),
      if (allowed.contains(AttachmentKind.audio))
        const XTypeGroup(label: 'Audio', extensions: audioExtensions, uniformTypeIdentifiers: ['public.audio']),
    ],
  );
}

/// Reads picked or dropped files. Files over a size limit (per kind, or the
/// message total on top of [alreadyBytes]) are left out and reported to
/// [onError]; nothing is truncated.
Future<List<Attachment>> readAttachments(
  Iterable<XFile> files, {
  int alreadyBytes = 0,
  required void Function(String message) onError,
}) async {
  final out = <Attachment>[];
  var total = alreadyBytes;
  for (final f in files) {
    final bytes = await f.readAsBytes();
    final (:attachment, :error) = Attachment.from(id: const Uuid().v4(), name: f.name, bytes: bytes, mime: f.mimeType);
    if (error != null) {
      onError(error);
      continue;
    }
    if (total + bytes.length > maxMessageBytes) {
      onError('${f.name} would take this message past ${formatBytes(maxMessageBytes)}.');
      continue;
    }
    total += bytes.length;
    out.add(attachment!);
  }
  return out;
}

/// Accepts files dragged onto [child], highlighting it while they hover.
class AttachmentDropZone extends StatefulWidget {
  const AttachmentDropZone({super.key, required this.onFiles, required this.child, this.enabled = true});

  final ValueChanged<List<XFile>> onFiles;
  final Widget child;
  final bool enabled;

  @override
  State<AttachmentDropZone> createState() => _AttachmentDropZoneState();
}

class _AttachmentDropZoneState extends State<AttachmentDropZone> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      enable: widget.enabled,
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: (details) {
        setState(() => _hovering = false);
        if (details.files.isNotEmpty) widget.onFiles(details.files);
      },
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: _hovering ? 0.7 : 1,
        child: widget.child,
      ),
    );
  }
}
