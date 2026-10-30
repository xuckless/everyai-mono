import 'highlighter.dart';

/// Whole file names that say what they hold.
const Map<String, String> _byName = <String, String>{
  'dockerfile': 'dockerfile',
  'containerfile': 'dockerfile',
  'makefile': 'makefile',
  'gnumakefile': 'makefile',
  'gemfile': 'ruby',
  'rakefile': 'ruby',
  'podfile': 'ruby',
  'cmakelists.txt': 'makefile',
  '.bashrc': 'bash',
  '.zshrc': 'bash',
  '.profile': 'bash',
  '.bash_profile': 'bash',
  '.env': 'ini',
  '.gitconfig': 'ini',
  '.editorconfig': 'ini',
};

/// Extensions the grammars' own aliases don't cover.
const Map<String, String> _byExtension = <String, String>{
  'mjs': 'javascript',
  'cjs': 'javascript',
  'mts': 'typescript',
  'cts': 'typescript',
  'pyi': 'python',
  'pyw': 'python',
  'hpp': 'cpp',
  'hh': 'cpp',
  'hxx': 'cpp',
  'cc': 'cpp',
  'cxx': 'cpp',
  'm': 'objectivec',
  'mm': 'objectivec',
  'kts': 'kotlin',
  'gradle': 'kotlin',
  'sc': 'scala',
  'bash': 'bash',
  'fish': 'bash',
  'psm1': 'powershell',
  'arb': 'json',
  'jsonl': 'json',
  'ipynb': 'json',
  'cfg': 'ini',
  'conf': 'ini',
  'properties': 'ini',
  'plist': 'xml',
  'xib': 'xml',
  'storyboard': 'xml',
  'csproj': 'xml',
  'vue': 'xml',
  'markdown': 'markdown',
  'mdx': 'markdown',
  'rmd': 'markdown',
  'graphqls': 'graphql',
  'mk': 'makefile',
};

/// The highlighter grammar for a file at [path] (by name, then extension),
/// or `null` when there is none, so callers show plain text.
String? languageForPath(String path) {
  final slash = path.lastIndexOf(RegExp(r'[/\\]'));
  final name = path.substring(slash + 1).trim().toLowerCase();
  if (name.isEmpty) return null;
  if (_byName[name] case final lang?) return lang;
  if (name.startsWith('dockerfile.') || name.endsWith('.dockerfile')) return 'dockerfile';
  if (name.startsWith('.env.')) return 'ini';
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  final ext = name.substring(dot + 1);
  return CodeHighlighter.resolve(_byExtension[ext] ?? ext);
}
