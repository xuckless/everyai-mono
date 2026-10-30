import 'learn_sources_stub.dart' if (dart.library.io) 'learn_sources_io.dart' as impl;

/// A file read for `/learn`, by its path relative to the folder.
typedef LearnDocument = ({String path, String text});

/// The most files and characters `/learn` reads from a folder.
const maxLearnFiles = 40;
const maxLearnChars = 60000;

/// Whether [path] is a folder (`~` expanded).
bool isFolder(String path) => impl.isFolder(expandHome(path));

/// [path] with a leading `~` replaced by the home folder.
String expandHome(String path) => impl.expandHome(path);

/// Whether [path] holds a `SKILL.md` at its top or one level down (it is
/// already a skill, or a folder of skills, to import as it is).
Future<bool> holdsSkills(String path) => impl.holdsSkills(expandHome(path));

/// The text files under [path] worth learning from, docs first, within
/// [maxLearnFiles] and [maxLearnChars]. Hidden folders, dependencies and build
/// output are skipped.
Future<List<LearnDocument>> readLearnFolder(String path) => impl.readFolder(expandHome(path));
