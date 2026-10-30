import '../harness/events.dart';
import 'shell_readonly.dart';

/// How much the agent may do without asking.
enum AgentMode {
  /// Reads are free; every command and edit waits for approval.
  ask('Ask', 'Approve every command and edit'),

  /// File edits go through; commands still wait for approval.
  autoEdit('Auto-edit', 'Edits apply; commands need approval'),

  /// Reads and plans only, then waits for "Start building".
  plan('Plan', 'Read the code and propose a plan first'),

  /// Nothing waits (the worktree keeps the main checkout safe).
  fullAuto('Full auto', 'Runs commands and edits without asking');

  const AgentMode(this.label, this.description);
  final String label;
  final String description;

  /// The agent-server confirmation policy. Auto-edit and plan confirm
  /// everything server-side and approve the safe parts in the app.
  Map<String, Object?> get confirmationPolicy => {'kind': this == fullAuto ? 'NeverConfirm' : 'AlwaysConfirm'};

  /// Whether the app approves [call] on its own in this mode.
  bool autoApproves(ActionCall call) {
    final readOnly = isReadOnly(call);
    return switch (this) {
      fullAuto => true,
      autoEdit => readOnly || call.actionKind == 'FileEditorAction' || _isClientTool(call),
      plan => readOnly || _isClientTool(call),
      ask => readOnly || _isClientTool(call),
    };
  }

  /// Plan mode refuses anything that changes the workspace.
  bool rejects(ActionCall call) => this == plan && !isReadOnly(call) && !_isClientTool(call);

  static bool _isClientTool(ActionCall call) => clientTools.contains(call.toolName);

  /// Actions that only look: viewing files, listing, searching, planning.
  static bool isReadOnly(ActionCall call) => switch (call.actionKind) {
    'FileEditorAction' => call.str('command') == 'view',
    'ReadFileAction' || 'GlobAction' || 'GrepAction' || 'ListDirectoryAction' => true,
    'TaskTrackerAction' || 'ThinkAction' || 'FinishAction' => true,
    // is_input sends keys to a running process.
    'TerminalAction' => call.action['is_input'] != true && isReadOnlyShell(call.str('command')),
    _ => false,
  };

  /// Why Plan mode refused an action, phrased so the agent keeps exploring
  /// instead of concluding its tools are broken.
  static const planRefusal =
      'Not run: Plan mode is read-only. Viewing files and read-only commands (cat, ls, rg, grep, find, sed -n, '
      'git status/log/diff/show) still run without approval, so keep exploring with those. When you know what to '
      'change, call present_plan and stop.';

  /// What the agent is told when a message is sent in this mode (see
  /// [modeNote]). Each note stands alone; the latest one wins.
  String get instructions => switch (this) {
    ask =>
      'Mode: Ask. Use your tools: viewing files and read-only commands run at once; edits and other commands '
          'wait for the user to approve them in the app, so propose them as tool calls rather than describing them. '
          'Restrictions from earlier mode notes no longer apply.',
    autoEdit =>
      'Mode: Auto-edit. File edits apply at once and read-only commands run freely; other commands wait for the '
          "user's approval. Do the work with your tools and verify it. Restrictions from earlier mode notes no "
          'longer apply.',
    plan =>
      'Mode: Plan. Investigate before proposing: view files and run read-only commands (cat, ls, rg, grep, find, '
          'sed -n, git status/log/diff/show); they run without approval. Do not edit files or run commands that change '
          "anything. Ask with ask_user_question when a decision is genuinely the user's. When you understand the "
          'change, call present_plan with concrete steps naming the files involved, then stop and wait.',
    fullAuto =>
      'Mode: Full auto. Every command and edit runs without approval. Do the task end to end: read the code, '
          'make the change, run the tests or build, and fix what fails. Restrictions from earlier mode notes no '
          'longer apply.',
  };
}

/// The tag a user message starts with to tell the agent its mode.
const _noteOpen = '<everyai-mode name="';
const _noteClose = '</everyai-mode>';

/// [text] prefixed with [mode]'s instructions. The app sends one with the
/// first message and with the first message after every mode change.
String modeNote(AgentMode mode, String text) =>
    '$_noteOpen${mode.name}">${mode.instructions}$_noteClose${text.isEmpty ? '' : '\n\n$text'}';

/// Splits a mode note off a user message: the mode (null without a note) and
/// the text the user wrote.
(AgentMode?, String) splitModeNote(String text) {
  if (!text.startsWith(_noteOpen)) return (null, text);
  final nameEnd = text.indexOf('"', _noteOpen.length);
  final end = text.indexOf(_noteClose);
  if (nameEnd < 0 || end < 0) return (null, text);
  final name = text.substring(_noteOpen.length, nameEnd);
  final mode = AgentMode.values.where((m) => m.name == name).firstOrNull;
  return (mode, text.substring(end + _noteClose.length).trimLeft());
}

/// How EveryAI wants the agent to work, appended to OpenHands' system prompt.
/// Constant, so prompt caching keeps working.
const workingRules = '''
<everyai>
You are the coding agent inside EveryAI. The user watches your tool calls in a desktop app.
- Act through your tools. Read the relevant code before proposing or changing anything; never answer with
  instructions for the user to carry out when you can do the work yourself.
- Your workspace is the current working directory, a checkout of the user's project. Files the user attaches are
  saved under .everyai/uploads/ there.
- User messages may start with an <everyai-mode> note. Follow the latest note; it replaces earlier ones.
- If a tool call is refused, read the reason and continue within it. Never claim your tools or files are
  unavailable without trying them.
- Use ask_user_question only for decisions that are genuinely the user's. After calling it, end your turn. When the
  answers arrive, carry on with the task.
- Before saying you are done, verify the change: run the tests, the build or the program, and report what you ran.
</everyai>''';

/// The question-card client tool (see AGENTS.md "Question cards").
const askUserQuestionTool = 'ask_user_question';

/// Registered with `client_tools` when a session starts.
const askUserQuestionSpec = <String, Object?>{
  'name': askUserQuestionTool,
  'description':
      'Ask the user 1-4 multiple-choice questions when a decision is genuinely theirs (scope, design, '
      'trade-offs) and you cannot resolve it from the code. Each question has 2-4 options with a short label '
      'and a description; set multi_select when several answers can apply. The user can also write their own '
      'answer. After calling this tool, stop and end your turn: the answers arrive as the next user message.',
  'parameters': {
    'type': 'object',
    'properties': {
      'questions': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 4,
        'items': {
          'type': 'object',
          'properties': {
            'question': {'type': 'string', 'description': 'The full question, ending with ?'},
            'header': {'type': 'string', 'description': 'A 1-3 word label, e.g. "Database"'},
            'multi_select': {'type': 'boolean'},
            'options': {
              'type': 'array',
              'minItems': 2,
              'maxItems': 4,
              'items': {
                'type': 'object',
                'properties': {
                  'label': {'type': 'string'},
                  'description': {'type': 'string'},
                },
                'required': ['label'],
              },
            },
          },
          'required': ['question', 'options'],
        },
      },
    },
    'required': ['questions'],
  },
  'annotations': {'readOnlyHint': true, 'destructiveHint': false},
};

/// Plan mode's hand-off: the agent proposes, the user approves or revises.
const presentPlanTool = 'present_plan';

/// The client tools registered with every session.
const clientTools = {askUserQuestionTool, presentPlanTool};

const presentPlanSpec = <String, Object?>{
  'name': presentPlanTool,
  'description':
      'Present your implementation plan to the user for approval. Use it in Plan mode once you have read enough '
      'of the code to be specific. Each step says what changes and in which files. After calling this tool, stop '
      'and end your turn: the user either approves (you will be told to build it) or replies with changes.',
  'parameters': {
    'type': 'object',
    'properties': {
      'title': {'type': 'string', 'description': 'A short name for the change'},
      'summary': {'type': 'string', 'description': 'One or two sentences on the approach'},
      'steps': {
        'type': 'array',
        'minItems': 1,
        'items': {
          'type': 'object',
          'properties': {
            'title': {'type': 'string', 'description': 'What this step does'},
            'detail': {'type': 'string', 'description': 'How, briefly'},
            'files': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Files created or changed',
            },
          },
          'required': ['title'],
        },
      },
      'risks': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Open questions or things that could go wrong',
      },
      'verification': {'type': 'string', 'description': 'How you will check the change works'},
    },
    'required': ['title', 'steps'],
  },
  'annotations': {'readOnlyHint': true, 'destructiveHint': false},
};
