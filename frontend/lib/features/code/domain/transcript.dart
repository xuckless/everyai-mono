import 'package:flutter/foundation.dart';

import '../harness/events.dart';
import 'agent_mode.dart';
import 'questions.dart';

/// What the session view shows, folded from harness events by
/// [TranscriptBuilder].
@immutable
sealed class TranscriptItem {
  const TranscriptItem(this.key);

  /// Stable across rebuilds (the first event's id).
  final String key;
}

final class UserTurn extends TranscriptItem {
  const UserTurn(super.key, this.text);
  final String text;
}

final class AgentText extends TranscriptItem {
  const AgentText(super.key, this.text, {this.reasoning = ''});
  final String text;
  final String reasoning;
}

/// One tool call and (once it lands) its result.
@immutable
final class ToolStep {
  const ToolStep(this.call, [this.result]);
  final ActionCall call;
  final ToolResult? result;

  bool get done => result != null;
  bool get failed => result?.outcome == ToolOutcome.error;
  bool get rejected => result?.outcome == ToolOutcome.rejected;

  ToolStep withResult(ToolResult r) => ToolStep(call, r);
}

/// A run of read-only steps ("Explored 3 files, 2 searches"), collapsed.
final class ExploreGroup extends TranscriptItem {
  const ExploreGroup(super.key, this.steps);
  final List<ToolStep> steps;
}

/// A command, an edit, or any other single tool call.
final class StepItem extends TranscriptItem {
  StepItem(this.step) : super(step.call.id);
  final ToolStep step;
}

/// A delegated subagent task.
final class SubagentItem extends TranscriptItem {
  SubagentItem(this.step) : super(step.call.id);
  final ToolStep step;

  /// name → task.
  Map<String, String> get tasks => {
    for (final e in ((step.call.action['tasks'] as Map<String, Object?>?) ?? const {}).entries) e.key: '${e.value}',
  };
}

final class PlanItem extends TranscriptItem {
  const PlanItem(super.key, this.tasks);
  final List<PlanTask> tasks;
}

@immutable
final class PlanTask {
  const PlanTask(this.title, this.status, [this.notes = '']);
  final String title;

  /// todo, in_progress or done.
  final String status;
  final String notes;
}

/// An `ask_user_question` card. [answers] is null until answered; empty when
/// the user replied in their own words instead.
final class QuestionItem extends TranscriptItem {
  QuestionItem(this.call, this.questions, [this.answers]) : super(call.id);
  final ActionCall call;
  final List<Question> questions;
  final List<QuestionAnswer>? answers;
}

final class NoticeItem extends TranscriptItem {
  const NoticeItem(super.key, this.message, {this.error = false});
  final String message;
  final bool error;
}

@immutable
final class Transcript {
  const Transcript({
    this.items = const [],
    this.streaming = '',
    this.streamingReasoning = '',
    this.status = ExecutionStatus.idle,
    this.plan = const [],
    this.pending = const [],
  });

  final List<TranscriptItem> items;

  /// The reply being written.
  final String streaming;
  final String streamingReasoning;
  final ExecutionStatus status;

  /// The latest task list, for the sticky plan card.
  final List<PlanTask> plan;

  /// Actions waiting for approval.
  final List<ActionCall> pending;

  /// The card waiting for answers: the latest unanswered one since the user
  /// last spoke. The agent's own text after it ("I've asked…") doesn't close it.
  QuestionItem? get openQuestion {
    for (final item in items.reversed) {
      if (item is UserTurn) return null;
      if (item is QuestionItem && item.answers == null) return item;
    }
    return null;
  }

  bool get running => status == ExecutionStatus.running;
}

/// Folds events into a [Transcript]. Mutable on the inside, immutable
/// snapshots out; feed events in order with [add].
final class TranscriptBuilder {
  final _items = <TranscriptItem>[];

  /// actionId → index in [_items].
  final _byAction = <String, int>{};
  final _byToolCall = <String, String>{};
  final _open = <String, ActionCall>{};
  final _streaming = StringBuffer();
  final _reasoning = StringBuffer();
  var _status = ExecutionStatus.idle;
  var _plan = const <PlanTask>[];

  Transcript get snapshot => Transcript(
    items: List.unmodifiable(_items),
    streaming: _streaming.toString(),
    streamingReasoning: _reasoning.toString(),
    status: _status,
    plan: _plan,
    pending: _status == ExecutionStatus.waitingForConfirmation ? _unanswered() : const [],
  );

  /// Every action without a result yet, whatever item it renders as.
  List<ActionCall> _unanswered() => List.unmodifiable(_open.values);

  void add(HarnessEvent e) {
    if (e is! StreamDelta && e is! StateChange) {
      _streaming.clear();
      _reasoning.clear();
    }
    switch (e) {
      case StreamDelta(:final content, :final reasoning):
        _streaming.write(content);
        _reasoning.write(reasoning);
      case StateChange(:final executionStatus) when executionStatus != ExecutionStatus.unknown:
        _status = executionStatus;
      case StateChange():
        break;
      case ChatMessage(fromUser: true, :final text):
        if (_answer(text)) return;
        _items.add(UserTurn(e.id, text));
        _closeOpenQuestion();
      case ChatMessage(:final text, :final reasoning):
        if (text.trim().isEmpty && reasoning.trim().isEmpty) return;
        _items.add(AgentText(e.id, text, reasoning: reasoning));
      case ActionCall():
        _action(e);
      case ToolResult():
        _result(e);
      case ConversationFailure(:final message):
        _items.add(NoticeItem(e.id, message, error: true));
      case UnknownEvent():
        break;
    }
  }

  void _action(ActionCall call) {
    _byToolCall[call.toolCallId] = call.id;
    _open[call.id] = call;
    if (call.toolName == askUserQuestionTool) {
      _push(call.id, QuestionItem(call, Question.listFrom(call.action)));
      return;
    }
    switch (call.actionKind) {
      case 'TaskTrackerAction':
        final tasks = [
          for (final t in (call.action['task_list'] as List<Object?>? ?? const []))
            if (t is Map<String, Object?>)
              PlanTask(t['title'] as String? ?? '', t['status'] as String? ?? 'todo', t['notes'] as String? ?? ''),
        ];
        if (tasks.isEmpty) return;
        _plan = tasks;
        // Consecutive plan updates replace each other.
        if (_items.lastOrNull is PlanItem) _items.removeLast();
        _push(call.id, PlanItem(call.id, tasks));
      case 'ThinkAction':
        _items.add(AgentText(call.id, '', reasoning: call.str('thought')));
      case 'FinishAction':
        final message = call.str('message');
        if (message.isNotEmpty) _items.add(AgentText(call.id, message));
      case 'DelegateAction' || 'TaskAction':
        if (call.thought.isNotEmpty) _items.add(AgentText('${call.id}-t', call.thought));
        _push(call.id, SubagentItem(ToolStep(call)));
      default:
        if (call.thought.isNotEmpty) _items.add(AgentText('${call.id}-t', call.thought));
        if (AgentMode.isReadOnly(call)) {
          if (_items.lastOrNull case final ExploreGroup g) {
            _items[_items.length - 1] = ExploreGroup(g.key, [...g.steps, ToolStep(call)]);
            _byAction[call.id] = _items.length - 1;
          } else {
            _push(call.id, ExploreGroup(call.id, [ToolStep(call)]));
          }
        } else {
          _push(call.id, StepItem(ToolStep(call)));
        }
    }
  }

  void _push(String actionId, TranscriptItem item) {
    _items.add(item);
    _byAction[actionId] = _items.length - 1;
  }

  void _result(ToolResult r) {
    final actionId = r.actionId.isNotEmpty ? r.actionId : (_byToolCall[r.toolCallId] ?? '');
    _open.remove(actionId);
    final i = _byAction[actionId];
    if (i == null) return;
    _items[i] = switch (_items[i]) {
      StepItem(:final step) => StepItem(step.withResult(r)),
      SubagentItem(:final step) => SubagentItem(step.withResult(r)),
      ExploreGroup(:final key, :final steps) => ExploreGroup(key, [
        for (final s in steps) s.call.id == actionId ? s.withResult(r) : s,
      ]),
      QuestionItem(:final call, :final questions, :final answers) when r.outcome == ToolOutcome.rejected =>
        QuestionItem(call, questions, answers ?? const []),
      final other => other,
    };
  }

  /// A reply in the user's own words settles any card still open.
  void _closeOpenQuestion() {
    for (var i = _items.length - 2; i >= 0; i--) {
      final item = _items[i];
      if (item is UserTurn) return;
      if (item is QuestionItem && item.answers == null) {
        _items[i] = QuestionItem(item.call, item.questions, const []);
        return;
      }
    }
  }

  /// Attaches an answers message to the open question card.
  bool _answer(String text) {
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      if (item is UserTurn) return false;
      if (item is QuestionItem && item.answers == null) {
        final answers = parseAnswers(text, item.questions);
        if (answers == null) return false;
        _items[i] = QuestionItem(item.call, item.questions, answers);
        return true;
      }
    }
    return false;
  }
}

/// A short label for a tool step ("Read lib/a.dart", "Ran flutter test").
String stepTitle(ActionCall call) {
  final path = call.str('path');
  return switch (call.actionKind) {
    'FileEditorAction' => switch (call.str('command')) {
      'view' => 'Read $path',
      'create' => 'Created $path',
      'undo_edit' => 'Undid edit to $path',
      _ => 'Edited $path',
    },
    'ReadFileAction' => 'Read ${call.str('file_path').isEmpty ? path : call.str('file_path')}',
    'WriteFileAction' => 'Wrote ${call.str('file_path').isEmpty ? path : call.str('file_path')}',
    'EditAction' => 'Edited ${call.str('file_path').isEmpty ? path : call.str('file_path')}',
    'GrepAction' => 'Searched for ${call.str('pattern')}',
    'GlobAction' => 'Listed ${call.str('pattern')}',
    'ListDirectoryAction' => 'Listed ${call.str('dir_path').isEmpty ? path : call.str('dir_path')}',
    'TerminalAction' => call.str('command'),
    'MCPToolAction' => 'Used ${call.toolName}',
    _ => call.summary.isNotEmpty ? call.summary : call.toolName,
  };
}

/// "Explored 2 files, 1 search".
String exploreSummary(List<ToolStep> steps) {
  var files = 0, searches = 0, commands = 0;
  for (final s in steps) {
    switch (s.call.actionKind) {
      case 'FileEditorAction' || 'ReadFileAction':
        files++;
      case 'GrepAction' || 'GlobAction' || 'ListDirectoryAction':
        searches++;
      case 'TerminalAction':
        final c = s.call.str('command').trimLeft();
        if (c.startsWith('grep') || c.startsWith('rg') || c.startsWith('find')) {
          searches++;
        } else {
          commands++;
        }
      default:
        commands++;
    }
  }
  String n(int count, String one, String many) => '$count ${count == 1 ? one : many}';
  return [
    if (files > 0) n(files, 'file', 'files'),
    if (searches > 0) n(searches, 'search', 'searches'),
    if (commands > 0) n(commands, 'command', 'commands'),
  ].join(', ');
}
