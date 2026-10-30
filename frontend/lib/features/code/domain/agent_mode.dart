import '../harness/events.dart';

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

  static bool _isClientTool(ActionCall call) => call.toolName == askUserQuestionTool;

  /// Actions that only look: viewing files, listing, searching, planning.
  static bool isReadOnly(ActionCall call) => switch (call.actionKind) {
    'FileEditorAction' => call.str('command') == 'view',
    'ReadFileAction' || 'GlobAction' || 'GrepAction' || 'ListDirectoryAction' => true,
    'TaskTrackerAction' || 'ThinkAction' || 'FinishAction' => true,
    'TerminalAction' => _readOnlyCommand(call.str('command')),
    _ => false,
  };

  static final _readOnly = RegExp(
    r'^\s*(ls|pwd|cat|head|tail|wc|find|grep|rg|tree|which|file|stat|git (status|log|diff|show|branch|remote)|echo)\b',
  );

  static bool _readOnlyCommand(String command) =>
      command.isNotEmpty && !RegExp(r'[;&|>]').hasMatch(command) && _readOnly.hasMatch(command);

  String get planPrompt =>
      'You are in plan mode. Explore the code read-only, then reply with a concise, numbered implementation '
      'plan and stop. Do not edit files or run commands that change anything until the user says to start.';
}

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
