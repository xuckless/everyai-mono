import 'learn_sources.dart' show LearnDocument;

bool isFolder(String path) => false;
String expandHome(String path) => path;
Future<bool> holdsSkills(String path) async => false;
Future<List<LearnDocument>> readFolder(String path) async => const [];
