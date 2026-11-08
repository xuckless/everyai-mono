// Language servers for diagnostics: which server a file needs, and how its findings read. Pure, so the web build and
// tests use it; the processes are in lsp_io.dart.

/// A language the diagnostics know a server for.
enum LspLanguage {
  typescript('TypeScript/JavaScript', 'typescript'),
  python('Python', 'python'),
  dart('Dart', 'dart'),
  go('Go', 'go'),
  rust('Rust', 'rust'),
  cpp('C/C++', 'cpp');

  const LspLanguage(this.label, this.id);
  final String label;

  /// The LSP `languageId` of its main kind of file.
  final String id;
}

/// The language of [path] by its extension, or null when no server is known for it.
LspLanguage? lspLanguageOf(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot < path.lastIndexOf('/')) return null;
  return switch (path.substring(dot + 1).toLowerCase()) {
    'ts' || 'tsx' || 'js' || 'jsx' || 'mts' || 'cts' || 'mjs' || 'cjs' => LspLanguage.typescript,
    'py' || 'pyi' => LspLanguage.python,
    'dart' => LspLanguage.dart,
    'go' => LspLanguage.go,
    'rs' => LspLanguage.rust,
    'c' || 'h' || 'cc' || 'cpp' || 'cxx' || 'hpp' || 'hh' || 'm' || 'mm' => LspLanguage.cpp,
    _ => null,
  };
}

/// The `languageId` LSP wants for [path] in [language] (TypeScript tells its four apart).
String lspLanguageId(LspLanguage language, String path) {
  final ext = path.substring(path.lastIndexOf('.') + 1).toLowerCase();
  return switch (language) {
    LspLanguage.typescript => switch (ext) {
      'tsx' => 'typescriptreact',
      'jsx' => 'javascriptreact',
      'js' || 'mjs' || 'cjs' => 'javascript',
      _ => 'typescript',
    },
    LspLanguage.cpp => ext == 'c' || ext == 'h' ? 'c' : (ext == 'm' ? 'objective-c' : 'cpp'),
    _ => language.id,
  };
}

/// A server command: what to run and with what.
typedef LspCommand = ({String exe, List<String> args});

/// The commands on the user's PATH that may serve [language], in the order they are tried; the pinned downloads
/// ([lspPinned]) come after them. Never a server from the project itself (node_modules/.bin, a virtualenv): the
/// diagnostics run without asking, so nothing the repository ships may run. TypeScript always runs on the pinned
/// install, with its own TypeScript, since the project's would load tsconfig plugins from the project's
/// node_modules.
List<({String name, List<String> args})> lspCandidates(LspLanguage language) => switch (language) {
  LspLanguage.typescript => const [],
  LspLanguage.python => const [
    (name: 'pyright-langserver', args: ['--stdio']),
    (name: 'basedpyright-langserver', args: ['--stdio']),
  ],
  LspLanguage.dart => const [
    (name: 'dart', args: ['language-server', '--protocol=lsp']),
  ],
  LspLanguage.go => const [(name: 'gopls', args: [])],
  LspLanguage.rust => const [(name: 'rust-analyzer', args: [])],
  LspLanguage.cpp => const [(name: 'clangd', args: [])],
};

/// What a server is started with, to keep the project's code from running: rust-analyzer's build scripts and
/// proc macros are off.
Map<String, Object?>? lspInitOptions(LspLanguage language) => switch (language) {
  LspLanguage.rust => const {
    'cargo': {
      'buildScripts': {'enable': false},
    },
    'procMacro': {'enable': false},
    'checkOnSave': false,
  },
  _ => null,
};

/// Why the server for [language] isn't started in [analysisOptions] (the project's analysis_options.yaml), or
/// null: analyzer plugins are packages the project names, and the Dart server would run them.
String? lspProjectCodeRefusal(LspLanguage language, {String analysisOptions = ''}) =>
    language == LspLanguage.dart && RegExp(r'^\s*plugins\s*:', multiLine: true).hasMatch(analysisOptions)
    ? "analysis_options.yaml loads analyzer plugins (code from the project's packages), so EveryAI doesn't start "
          'the Dart server itself. Run dart analyze instead.'
    : null;

/// The servers EveryAI installs itself when the user has none (npm packages at pinned versions; `npm ci` checks
/// each against the integrity hash in the bundled lockfile, `assets/lsp/<id>/package-lock.json`). Only where the
/// user has Node, which these run on.
const lspPinned = {
  LspLanguage.typescript: (id: 'typescript', bin: 'typescript-language-server', args: ['--stdio']),
  LspLanguage.python: (id: 'pyright', bin: 'pyright-langserver', args: ['--stdio']),
};

/// One finding, 1-based like an editor shows it.
typedef LspDiagnostic = ({int line, int column, int severity, String message, String source});

/// A `publishDiagnostics` (or pulled report) item as a [LspDiagnostic]; null when it isn't one.
LspDiagnostic? lspDiagnosticOf(Object? raw) {
  if (raw is! Map) return null;
  final start = (raw['range'] as Map?)?['start'] as Map?;
  final message = raw['message'];
  if (start == null || message is! String) return null;
  return (
    line: ((start['line'] as num?)?.toInt() ?? 0) + 1,
    column: ((start['character'] as num?)?.toInt() ?? 0) + 1,
    // LSP: 1 error, 2 warning, 3 information, 4 hint; missing means error.
    severity: (raw['severity'] as num?)?.toInt() ?? 1,
    message: message.trim(),
    source: '${raw['source'] ?? ''}',
  );
}

int lspErrors(Iterable<LspDiagnostic> d) => d.where((x) => x.severity == 1).length;

/// [byFile] (path relative to the project → findings) as the diagnostics tool's text: errors before warnings, at
/// most [max] lines, information and hints left out.
String formatDiagnostics(Map<String, List<LspDiagnostic>> byFile, {int max = 60}) {
  final rows = <(int, String)>[];
  for (final MapEntry(key: path, value: list) in byFile.entries) {
    for (final d in list.where((d) => d.severity <= 2)) {
      final kind = d.severity == 1 ? 'error' : 'warning';
      final from = d.source.isEmpty ? '' : ' [${d.source}]';
      rows.add((d.severity, '$path:${d.line}:${d.column}: $kind: ${d.message.split('\n').first}$from'));
    }
  }
  if (rows.isEmpty) {
    return byFile.isEmpty ? 'No files were checked.' : 'No errors or warnings in ${_files(byFile.length)}.';
  }
  rows.sort((a, b) => a.$1.compareTo(b.$1));
  final errors = rows.where((r) => r.$1 == 1).length;
  final head =
      '$errors error${errors == 1 ? '' : 's'}, ${rows.length - errors} warning'
      '${rows.length - errors == 1 ? '' : 's'} in ${_files(byFile.length)}:';
  final shown = rows.take(max).map((r) => r.$2);
  final more = rows.length > max ? '\n… and ${rows.length - max} more.' : '';
  return '$head\n${shown.join('\n')}$more';
}

String _files(int n) => '$n file${n == 1 ? '' : 's'}';

/// The one line an edit's result gets when it left [path] with more errors than before ([before] → [after]).
/// Prompt reason: the model should know an edit broke something without the result filling with diagnostics; the
/// diagnostics tool has the details.
String? editDiagnosticsHint(String path, int before, int after) {
  if (after <= before) return null;
  final added = after - before;
  return 'This edit added $added error${added == 1 ? '' : 's'} in $path; call diagnostics to see '
      '${added == 1 ? 'it' : 'them'}.';
}

/// The paths an apply_patch [patch] writes (added, updated, moved to), as written in it.
List<String> patchTargets(String patch) => [
  for (final line in patch.split('\n'))
    if (RegExp(r'^\*\*\* (Add File|Update File|Move to): (.+)$').firstMatch(line.trimRight()) case final m?)
      m[2]!.trim(),
];
