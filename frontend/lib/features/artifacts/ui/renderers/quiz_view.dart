import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../chat/chat_providers.dart';
import '../../../chat/ui/chat_markdown.dart';
import '../../artifact_providers.dart';
import '../../domain/artifact.dart';

const _good = Color(0xFF2FA866);

@immutable
final class _Question {
  const _Question(this.text, this.options, this.correct, this.explanation);

  static _Question? fromJson(Object? json) {
    if (json case {'question': final String q, 'options': final List<Object?> options}) {
      final m = json as Map<String, Object?>;
      final correct = <int>{
        if (m['answer_index'] case final num i) i.toInt(),
        if (m['answer_indices'] case final List<Object?> list) ...list.whereType<num>().map((n) => n.toInt()),
      };
      return _Question(q, options.map((o) => '$o').toList(), correct, m['explanation'] as String? ?? '');
    }
    return null;
  }

  final String text;
  final List<String> options;
  final Set<int> correct;
  final String explanation;

  /// More than one right answer: checkboxes and a Check button.
  bool get multiple => correct.length > 1;
}

/// Multiple-choice quiz. Single-answer questions are radio-style and lock on
/// the first pick; multiple-answer questions use checkboxes and a Check
/// button. Each answer reveals the explanation; the score and "Explain my
/// mistakes" appear once every question is answered.
class QuizView extends ConsumerStatefulWidget {
  const QuizView({super.key, required this.visual, required this.conversationId});

  final Visual visual;
  final String conversationId;

  @override
  ConsumerState<QuizView> createState() => _QuizViewState();
}

class _QuizViewState extends ConsumerState<QuizView> {
  /// Checked but not yet submitted options of multiple-answer questions.
  final _pending = <int, Set<int>>{};

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final questions = ((widget.visual.args['questions'] as List<Object?>?) ?? const [])
        .map(_Question.fromJson)
        .nonNulls
        .toList();
    final provider = quizAnswersProvider(widget.visual.callId);
    final answers = ref.watch(provider);
    final ctl = ref.read(provider.notifier);

    bool isRight(int qi) =>
        questions[qi].correct.containsAll(_chosen(answers, qi)) &&
        _chosen(answers, qi).containsAll(questions[qi].correct);
    final done = questions.isNotEmpty && answers.length == questions.length;
    final score = [
      for (var i = 0; i < questions.length; i++)
        if (answers.containsKey(i) && isRight(i)) i,
    ].length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (qi, q) in questions.indexed) ...[
          Padding(
            padding: EdgeInsets.only(top: qi == 0 ? 0 : 18, bottom: 8),
            child: Text(
              '${qi + 1}. ${q.text}',
              style: TextStyle(color: theme.text, fontSize: 15, fontWeight: FontWeight.w600, height: 1.35),
            ),
          ),
          if (q.multiple && !answers.containsKey(qi))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('Select all that apply', style: TextStyle(color: theme.textMuted, fontSize: 12)),
            ),
          for (final (oi, option) in q.options.indexed)
            _Option(
              label: option,
              letter: String.fromCharCode(65 + oi),
              multiple: q.multiple,
              state: _optionState(q, answers.containsKey(qi), _chosen(answers, qi), _pending[qi] ?? const {}, oi),
              onTap: answers.containsKey(qi)
                  ? null
                  : () => setState(() {
                      if (!q.multiple) {
                        ctl.answer(qi, _encode({oi}));
                      } else {
                        final set = _pending[qi] ??= {};
                        set.contains(oi) ? set.remove(oi) : set.add(oi);
                      }
                    }),
            ),
          if (q.multiple && !answers.containsKey(qi))
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: AdaptiveButton(
                  label: 'Check',
                  emphasis: ButtonEmphasis.secondary,
                  onPressed: (_pending[qi]?.isEmpty ?? true) ? null : () => ctl.answer(qi, _encode(_pending[qi]!)),
                ),
              ),
            ),
          if (answers.containsKey(qi) && q.explanation.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                color: (isRight(qi) ? _good : theme.danger).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(theme.radius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isRight(qi) ? 'Correct' : 'Not quite',
                    style: TextStyle(
                      color: isRight(qi) ? _good : theme.danger,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  ChatMarkdown(q.explanation),
                ],
              ),
            ),
        ],
        if (done) ...[
          const SizedBox(height: 18),
          Row(
            children: [
              Text(
                'Score: $score / ${questions.length}',
                style: TextStyle(color: theme.text, fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              AdaptiveButton(
                label: 'Try again',
                emphasis: ButtonEmphasis.plain,
                onPressed: () => setState(() {
                  _pending.clear();
                  ctl.reset();
                }),
              ),
              if (score < questions.length)
                AdaptiveButton(
                  label: 'Explain my mistakes',
                  emphasis: ButtonEmphasis.secondary,
                  onPressed: () => ref
                      .read(chatSessionProvider(widget.conversationId).notifier)
                      .send(_mistakes(questions, answers, isRight)),
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// Answers are stored as one int per question: a bitmask of chosen options.
  static int _encode(Set<int> options) => options.fold(0, (mask, o) => mask | (1 << o));

  static Set<int> _chosen(Map<int, int> answers, int qi) {
    final mask = answers[qi];
    if (mask == null) return const {};
    return {
      for (var i = 0; i < 31; i++)
        if (mask & (1 << i) != 0) i,
    };
  }

  static _OptionState _optionState(_Question q, bool answered, Set<int> chosen, Set<int> pending, int oi) {
    if (!answered) return pending.contains(oi) ? _OptionState.selected : _OptionState.idle;
    if (q.correct.contains(oi)) return chosen.contains(oi) ? _OptionState.right : _OptionState.missed;
    return chosen.contains(oi) ? _OptionState.wrong : _OptionState.dimmed;
  }

  String _mistakes(List<_Question> questions, Map<int, int> answers, bool Function(int) isRight) {
    final b = StringBuffer('I took the quiz "${widget.visual.title}". Please explain what I got wrong:\n');
    for (final (qi, q) in questions.indexed) {
      if (isRight(qi)) continue;
      final mine = _chosen(answers, qi).map((o) => q.options[o]).join(', ');
      final right = q.correct.map((o) => q.options[o]).join(', ');
      b.write('\n- "${q.text}": I answered "$mine"; the answer is "$right".');
    }
    return b.toString();
  }
}

enum _OptionState { idle, selected, right, wrong, missed, dimmed }

class _Option extends StatefulWidget {
  const _Option({
    required this.label,
    required this.letter,
    required this.multiple,
    required this.state,
    required this.onTap,
  });

  final String label;
  final String letter;
  final bool multiple;
  final _OptionState state;
  final VoidCallback? onTap;

  @override
  State<_Option> createState() => _OptionStateWidget();
}

class _OptionStateWidget extends State<_Option> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final (border, fill) = switch (widget.state) {
      _OptionState.right => (_good, _good.withValues(alpha: 0.12)),
      _OptionState.missed => (_good, null),
      _OptionState.wrong => (theme.danger, theme.danger.withValues(alpha: 0.12)),
      _OptionState.selected => (theme.accent, theme.accent.withValues(alpha: 0.12)),
      _ => (theme.border, _hover && widget.onTap != null ? theme.text.withValues(alpha: 0.05) : null),
    };
    final mark = switch (widget.state) {
      _OptionState.right || _OptionState.missed => AdaptiveIcon(EveryIcon.check, size: 14, color: _good),
      _OptionState.wrong => AdaptiveIcon(EveryIcon.close, size: 14, color: theme.danger),
      _ => null,
    };
    final box = Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: widget.state == _OptionState.selected ? theme.accent : null,
        border: Border.all(color: widget.state == _OptionState.selected ? theme.accent : theme.border, width: 1.5),
        borderRadius: BorderRadius.circular(widget.multiple ? 5 : 11),
      ),
      child: widget.state == _OptionState.selected
          ? AdaptiveIcon(EveryIcon.check, size: 13, color: theme.onAccent)
          : Text(
              widget.letter,
              style: TextStyle(color: theme.textMuted, fontSize: 11, fontWeight: FontWeight.w700),
            ),
    );
    return Semantics(
      button: widget.onTap != null,
      checked: widget.multiple ? widget.state == _OptionState.selected : null,
      label: widget.label,
      child: MouseRegion(
        cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: fill,
              border: Border.all(color: border),
              borderRadius: BorderRadius.circular(theme.radius),
            ),
            child: Opacity(
              opacity: widget.state == _OptionState.dimmed ? 0.55 : 1,
              child: Row(
                children: [
                  box,
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(widget.label, style: TextStyle(color: theme.text, fontSize: 14, height: 1.3)),
                  ),
                  ?mark,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
