import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../domain/questions.dart';
import '../../domain/transcript.dart';

/// The agent's `ask_user_question` card: 1–4 questions, each single-choice
/// (radio) or multiple-answer (checkboxes), every one with an "Other" field.
/// Answered cards collapse to a summary.
class QuestionCard extends StatefulWidget {
  const QuestionCard({super.key, required this.item, required this.onSubmit, this.enabled = true});

  final QuestionItem item;
  final ValueChanged<List<QuestionAnswer>> onSubmit;
  final bool enabled;

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  late List<QuestionAnswer> _answers = [for (final _ in widget.item.questions) const QuestionAnswer()];
  late final List<TextEditingController> _other = [for (final _ in widget.item.questions) TextEditingController()];
  bool _sent = false;

  @override
  void dispose() {
    for (final c in _other) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _complete => _answers.every((a) => !a.isEmpty);

  void _pick(int q, int option) {
    final question = widget.item.questions[q];
    final a = _answers[q];
    final selected = question.multiSelect
        ? (a.selected.contains(option) ? ({...a.selected}..remove(option)) : {...a.selected, option})
        : {option};
    // A single-choice pick replaces a typed "Other".
    if (!question.multiSelect) _other[q].clear();
    setState(() => _answers = [..._answers]..[q] = QuestionAnswer(selected: selected, other: _other[q].text));
  }

  void _typeOther(int q, String text) {
    final question = widget.item.questions[q];
    final selected = question.multiSelect || text.trim().isEmpty ? _answers[q].selected : <int>{};
    setState(() => _answers = [..._answers]..[q] = QuestionAnswer(selected: selected, other: text));
  }

  void _submit() {
    if (!_complete || _sent) return;
    setState(() => _sent = true);
    widget.onSubmit(_answers);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final item = widget.item;
    final answered = item.answers;
    final questions = item.questions;

    if (questions.isEmpty) {
      return Text('The agent asked an empty question.', style: TextStyle(color: theme.textMuted, fontSize: 13));
    }
    if (answered != null) return _Answered(questions: questions, answers: answered);

    final enabled = widget.enabled && !_sent;
    return Container(
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        border: Border.all(color: theme.accent.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.enter, meta: true): _submit},
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AdaptiveIcon(EveryIcon.quiz, size: 15, color: theme.accent),
                const SizedBox(width: 8),
                Text(
                  questions.length == 1 ? 'A question for you' : '${questions.length} questions for you',
                  style: TextStyle(color: theme.text, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            for (final (qi, q) in questions.indexed) ...[
              SizedBox(height: qi == 0 ? 12 : 18),
              Row(
                children: [
                  if (q.header.isNotEmpty) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.accent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        q.header,
                        style: TextStyle(color: theme.accent, fontSize: 11, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (q.multiSelect)
                    Text('Select all that apply', style: TextStyle(color: theme.textMuted, fontSize: 11.5)),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                q.question,
                style: TextStyle(color: theme.text, fontSize: 14.5, fontWeight: FontWeight.w600, height: 1.35),
              ),
              const SizedBox(height: 8),
              for (final (oi, option) in q.options.indexed)
                _OptionRow(
                  label: option.label,
                  description: option.description,
                  multiple: q.multiSelect,
                  selected: _answers[qi].selected.contains(oi),
                  onTap: enabled ? () => _pick(qi, oi) : null,
                ),
              _OtherRow(
                controller: _other[qi],
                multiple: q.multiSelect,
                active: _answers[qi].other.trim().isNotEmpty,
                enabled: enabled,
                onChanged: (t) => _typeOther(qi, t),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _complete ? '⌘↩ to submit' : 'Answer every question to continue',
                    style: TextStyle(color: theme.textMuted, fontSize: 12),
                  ),
                ),
                AdaptiveButton(
                  label: questions.length == 1 ? 'Submit answer' : 'Submit answers',
                  busy: _sent,
                  onPressed: _complete && enabled ? _submit : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A radio (round) or checkbox (square) choice with a label and description.
class _OptionRow extends StatefulWidget {
  const _OptionRow({
    required this.label,
    required this.description,
    required this.multiple,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String description;
  final bool multiple;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_OptionRow> createState() => _OptionRowState();
}

class _OptionRowState extends State<_OptionRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final selected = widget.selected;
    return Semantics(
      button: true,
      inMutuallyExclusiveGroup: !widget.multiple,
      checked: selected,
      label: widget.description.isEmpty ? widget.label : '${widget.label}. ${widget.description}',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? theme.accent.withValues(alpha: 0.10)
                  : _hover && widget.onTap != null
                  ? theme.text.withValues(alpha: 0.04)
                  : null,
              border: Border.all(color: selected ? theme.accent : theme.border),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: ChoiceMark(multiple: widget.multiple, selected: selected),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.label,
                        style: TextStyle(color: theme.text, fontSize: 13.5, fontWeight: FontWeight.w600),
                      ),
                      if (widget.description.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            widget.description,
                            style: TextStyle(color: theme.textMuted, fontSize: 12.5, height: 1.3),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OtherRow extends StatelessWidget {
  const _OtherRow({
    required this.controller,
    required this.multiple,
    required this.active,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool multiple;
  final bool active;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      decoration: BoxDecoration(
        color: active ? theme.accent.withValues(alpha: 0.10) : null,
        border: Border.all(color: active ? theme.accent : theme.border),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          ChoiceMark(multiple: multiple, selected: active),
          const SizedBox(width: 10),
          Expanded(
            child: IgnorePointer(
              ignoring: !enabled,
              child: AdaptiveTextField(
                controller: controller,
                placeholder: 'Other: type your own answer',
                borderless: true,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A radio dot or a checkbox.
class ChoiceMark extends StatelessWidget {
  const ChoiceMark({super.key, required this.multiple, required this.selected});

  final bool multiple;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected && multiple ? theme.accent : null,
        border: Border.all(color: selected ? theme.accent : theme.textMuted.withValues(alpha: 0.6), width: 1.5),
        borderRadius: BorderRadius.circular(multiple ? 4.5 : 9),
      ),
      child: !selected
          ? null
          : multiple
          ? AdaptiveIcon(EveryIcon.check, size: 12, color: theme.onAccent)
          : Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: theme.accent, shape: BoxShape.circle),
            ),
    );
  }
}

class _Answered extends StatelessWidget {
  const _Answered({required this.questions, required this.answers});

  final List<Question> questions;
  final List<QuestionAnswer> answers;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, q) in questions.indexed)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(q.question, style: TextStyle(color: theme.textMuted, fontSize: 12.5)),
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final label in (i < answers.length ? answers[i] : const QuestionAnswer()).labels(q))
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: theme.accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AdaptiveIcon(EveryIcon.check, size: 11, color: theme.accent),
                              const SizedBox(width: 4),
                              Text(
                                label,
                                style: TextStyle(color: theme.text, fontSize: 12.5, fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        ),
                      if (i >= answers.length || answers[i].isEmpty)
                        Text('Skipped', style: TextStyle(color: theme.textMuted, fontSize: 12.5)),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
