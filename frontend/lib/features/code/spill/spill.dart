import 'spill_stub.dart' if (dart.library.io) 'spill_io.dart' as impl;

/// Saves [text] as `.everyai/spill/<name>` under [workingDir] (kept out of git)
/// and returns the path relative to it, or null when it can't be written.
String? saveSpill(String workingDir, String name, String text) => impl.saveSpill(workingDir, name, text);
