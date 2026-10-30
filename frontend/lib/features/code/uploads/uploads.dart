import '../../attachments/attachment.dart';
import 'uploads_stub.dart' if (dart.library.io) 'uploads_io.dart' as impl;

/// Where attachments go inside a project, relative to its root (kept out of
/// git through `.git/info/exclude`).
const uploadsDir = '.everyai/uploads';

/// Copies [files] into [workingDir]/[uploadsDir] and returns their paths
/// relative to [workingDir], for the agent to open.
Future<List<String>> saveUploads(String workingDir, List<Attachment> files) => impl.saveUploads(workingDir, files);

/// The note appended to a message so the agent knows where the files are.
String attachedNote(List<String> paths) => '[Attached: ${paths.join(', ')}]';

/// Splits [attachedNote] back off a user message: (text, paths).
(String, List<String>) splitAttachedNote(String message) {
  final m = RegExp(r'\n*\[Attached: ([^\]]*)\]\s*$').firstMatch(message);
  if (m == null) return (message, const []);
  return (message.substring(0, m.start), m.group(1)!.split(', '));
}
