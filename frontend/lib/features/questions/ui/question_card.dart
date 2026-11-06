import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../core/motion/motion.dart';
import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../attachments/attachment.dart';
import '../../attachments/attachment_input.dart';
import '../../attachments/ui/attachment_tray.dart';
import '../../models/domain/model_catalog.dart';

import 'package:file_selector/file_selector.dart' show XFile;

import '../domain/questions.dart';

/// A question card, shared by Code's `ask_user_question` and Chat's
/// `ask_user`: 1–4 questions, each single-choice (radio) or multiple-answer
/// (checkboxes), every one with an "Other" field. Answered cards collapse to a
/// summary.
class QuestionCard extends StatefulWidget {
  const QuestionCard({
    super.key,
    required this.questions,
    required this.onSubmit,
    this.answers,
    this.enabled = true,
    this.closedLabel = 'Answered in chat',
    this.reply,
    this.onSubmitWithFiles,
    this.attachKinds,
    this.model,
    this.pickFiles = pickAttachmentFiles,
  });

  final List<Question> questions;

  /// Null while unanswered; empty when the user replied in chat instead.
  final List<QuestionAnswer>? answers;
  final ValueChanged<List<QuestionAnswer>> onSubmit;
  final bool enabled;

  /// The footer of a disabled card nobody answered from it.
  final String closedLabel;

  /// What the user wrote instead of picking options, for the answered summary.
  final String? reply;

  /// Set, the "Other" field gets an attach button and a submit goes here with the
  /// files instead of to [onSubmit]. False means it didn't go through: the card opens again.
  final Future<bool> Function(List<QuestionAnswer>, List<Attachment>)? onSubmitWithFiles;

  /// What the picker offers (null = any file) and the model the files go to, for the blind-model hint.
  final Set<AttachmentKind>? attachKinds;
  final ModelSpec? model;

  /// Opens the file picker (a test injects its own).
  final Future<List<XFile>> Function({Set<AttachmentKind>? allowed}) pickFiles;

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  late List<QuestionAnswer> _answers = [for (final _ in widget.questions) const QuestionAnswer()];
  late final List<TextEditingController> _other = [for (final _ in widget.questions) TextEditingController()];
  late final List<FocusNode> _otherFocus = [for (final _ in widget.questions) FocusNode()];
  final _focus = FocusNode(debugLabel: 'question card');
  int _page = 0;

  /// The way the last page change went: +1 forward, -1 back (the next pane slides in from that side).
  int _dir = 1;
  bool _sent = false;
  final _files = <Attachment>[];

  @override
  void dispose() {
    for (final c in _other) {
      c.dispose();
    }
    for (final f in _otherFocus) {
      f.dispose();
    }
    _focus.dispose();
    super.dispose();
  }

  List<Question> get _questions => widget.questions;
  bool get _paged => _questions.length > 1;
  bool get _complete => _answers.every((a) => !a.isEmpty);
  bool get _typing => _otherFocus.any((f) => f.hasFocus);
  bool get _enabled => widget.enabled && !_sent;

  void _pick(int q, int option) {
    final question = _questions[q];
    final a = _answers[q];
    final selected = question.multiSelect
        ? (a.selected.contains(option) ? ({...a.selected}..remove(option)) : {...a.selected, option})
        : {option};
    // A single-choice pick replaces a typed "Other".
    if (!question.multiSelect) _other[q].clear();
    setState(() => _answers = [..._answers]..[q] = QuestionAnswer(selected: selected, other: _other[q].text));
    _focus.requestFocus();
    // Single choice moves on to the next unanswered question.
    if (!question.multiSelect && q == _page && _page < _questions.length - 1) {
      Future.delayed(const Duration(milliseconds: 180), () {
        if (mounted && _page == q) {
          setState(() {
            _dir = 1;
            _page++;
          });
        }
      });
    }
  }

  void _typeOther(int q, String text) {
    final question = _questions[q];
    final selected = question.multiSelect || text.trim().isEmpty ? _answers[q].selected : <int>{};
    setState(() => _answers = [..._answers]..[q] = QuestionAnswer(selected: selected, other: text));
  }

  void _go(int page) {
    if (page < 0 || page >= _questions.length || page == _page) return;
    setState(() {
      _dir = page > _page ? 1 : -1;
      _page = page;
    });
  }

  /// ↩: next question, or submit on the last one.
  void _advance() {
    if (_page < _questions.length - 1) {
      _go(_page + 1);
    } else {
      _submit();
    }
  }

  void _submit() {
    if (!_complete || !_enabled) {
      // Jump to the first question still missing an answer.
      final missing = _answers.indexWhere((a) => a.isEmpty);
      if (missing >= 0) _go(missing);
      return;
    }
    setState(() => _sent = true);
    if (widget.onSubmitWithFiles case final submit?) {
      submit(_answers, List.unmodifiable(_files)).then((ok) {
        if (!ok && mounted) setState(() => _sent = false);
      });
      return;
    }
    widget.onSubmit(_answers);
  }

  Future<void> _attach() async {
    final picked = await widget.pickFiles(allowed: widget.attachKinds);
    if (!mounted || !_enabled) return;
    final added = await readPicked(
      picked,
      alreadyBytes: _files.fold(0, (sum, a) => sum + a.size),
      kinds: widget.attachKinds,
      onMessage: (message) {
        if (mounted) showAdaptiveToast(context, message);
      },
    );
    // A card submitted or closed meanwhile has sent its files already.
    if (mounted && _enabled && added.isNotEmpty) setState(() => _files.addAll(added));
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
    const SingleActivator(LogicalKeyboardKey.enter, meta: true): _submit,
    const SingleActivator(LogicalKeyboardKey.enter, control: true): _submit,
    const SingleActivator(LogicalKeyboardKey.enter): () {
      if (!_typing) _advance();
    },
    if (_paged) ...{
      const SingleActivator(LogicalKeyboardKey.arrowRight): () {
        if (!_typing) _go(_page + 1);
      },
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
        if (!_typing) _go(_page - 1);
      },
    },
    for (final (i, key) in _digits.indexed)
      SingleActivator(key): () {
        if (!_typing && _enabled && i < _questions[_page].options.length) _pick(_page, i);
      },
  };

  static const _digits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final answered = widget.answers;
    final questions = _questions;

    if (questions.isEmpty) {
      return Text('The agent asked an empty question.', style: theme.type.callout.tint(theme.textMuted));
    }
    if (answered != null) return _Answered(questions: questions, answers: answered, reply: widget.reply);

    final enabled = _enabled;
    final page = _page.clamp(0, questions.length - 1);
    final missing = [
      for (final (i, a) in _answers.indexed)
        if (a.isEmpty) questions[i].header.isNotEmpty ? questions[i].header : 'question ${i + 1}',
    ];
    final last = page == questions.length - 1;

    final reduced = Motion.reduced(context);
    final footnote = !enabled && !_sent
        ? widget.closedLabel
        : missing.isEmpty
        ? ''
        : _paged && last
        ? '${missing.length} left'
        : '';
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
      ),
      child: CallbackShortcuts(
        bindings: _shortcuts,
        child: Focus(
          focusNode: _focus,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_paged) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 14, 0),
                  child: Row(
                    children: [
                      Expanded(
                        // Many questions scroll sideways rather than squeezing the tabs.
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: KitTabs<int>(
                            key: const ValueKey('question.tabs'),
                            values: [for (var i = 0; i < questions.length; i++) i],
                            selected: page,
                            onSelected: _go,
                            label: (i) => questions[i].header.isNotEmpty ? questions[i].header : 'Q${i + 1}',
                            leading: (i) => StateSwap(
                              child: _answers[i].isEmpty
                                  ? StatusDot(
                                      i == page ? DotStatus.running : DotStatus.idle,
                                      key: const ValueKey('todo'),
                                      size: 6,
                                    )
                                  : AdaptiveIcon(
                                      EveryIcon.check,
                                      key: const ValueKey('done'),
                                      size: 12,
                                      color: theme.success,
                                    ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('${page + 1} of ${questions.length}', style: theme.type.caption.tint(theme.textSubtle)),
                    ],
                  ),
                ),
                Container(height: 1, color: theme.border),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 460),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                  child: AnimatedSwitcher(
                    duration: reduced ? Duration.zero : Motion.move,
                    switchInCurve: Motion.easeInOut,
                    switchOutCurve: Motion.easeInOut,
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.topCenter,
                      children: [
                        ...previous.map((w) => Positioned(left: 0, right: 0, top: 0, child: w)),
                        ?current,
                      ],
                    ),
                    transitionBuilder: (child, animation) {
                      // The new pane comes in from the side it lies on; the old one leaves the other way.
                      final incoming = child.key == ValueKey(page);
                      final dx = (incoming ? 18.0 : -18.0) * _dir;
                      return FadeTransition(
                        opacity: animation,
                        child: AnimatedBuilder(
                          animation: animation,
                          builder: (context, c) =>
                              Transform.translate(offset: Offset(dx * (1 - animation.value), 0), child: c),
                          child: child,
                        ),
                      );
                    },
                    child: _QuestionPage(
                      key: ValueKey(page),
                      question: questions[page],
                      showHeader: !_paged,
                      answer: _answers[page],
                      other: _other[page],
                      otherFocus: _otherFocus[page],
                      enabled: enabled,
                      onPick: (oi) => _pick(page, oi),
                      onOther: (t) => _typeOther(page, t),
                      onOtherSubmitted: _advance,
                      onAttach: widget.onSubmitWithFiles == null ? null : _attach,
                    ),
                  ),
                ),
              ),
              if (_files.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: AttachmentTray(
                    attachments: _files,
                    model: widget.model,
                    onRemove: (a) => setState(() => _files.remove(a)),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Row(
                  children: [
                    if (_paged && page > 0)
                      KitButton(
                        key: const ValueKey('question.back'),
                        label: 'Back',
                        style: KitButtonStyle.ghost,
                        onPressed: () => _go(page - 1),
                      ),
                    const Spacer(),
                    if (footnote.isNotEmpty)
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: Text(
                            footnote,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.type.caption.tint(theme.textSubtle),
                          ),
                        ),
                      ),
                    if (_paged && !last)
                      KitButton(
                        key: const ValueKey('question.next'),
                        label: 'Next',
                        style: _complete ? KitButtonStyle.soft : KitButtonStyle.primary,
                        onPressed: () => _go(page + 1),
                      ),
                    if (!_paged || last || _complete) ...[
                      if (_paged && !last) const SizedBox(width: 6),
                      KitButton(
                        key: const ValueKey('question.submit'),
                        label: questions.length == 1 ? 'Submit answer' : 'Submit answers',
                        shortcut: Host.isDesktop ? Host.enterKeys(command: true) : null,
                        onPressed: _complete && enabled && !_sent ? _submit : null,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One question: its header, text, options and the "Other" field.
class _QuestionPage extends StatelessWidget {
  const _QuestionPage({
    super.key,
    required this.question,
    required this.showHeader,
    required this.answer,
    required this.other,
    required this.otherFocus,
    required this.enabled,
    required this.onPick,
    required this.onOther,
    required this.onOtherSubmitted,
    this.onAttach,
  });

  final Question question;
  final bool showHeader;
  final QuestionAnswer answer;
  final TextEditingController other;
  final FocusNode otherFocus;
  final bool enabled;
  final ValueChanged<int> onPick;
  final ValueChanged<String> onOther;
  final VoidCallback onOtherSubmitted;
  final VoidCallback? onAttach;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final q = question;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader && q.header.isNotEmpty) ...[
          Align(alignment: Alignment.centerLeft, child: _HeaderChip(q.header)),
          const SizedBox(height: 8),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(q.question, style: theme.type.body.medium.tint(theme.text).copyWith(height: 1.35))),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(q.multiSelect ? 'Pick any' : 'Pick one', style: theme.type.caption.tint(theme.textSubtle)),
              ),
            ],
          ),
        ),
        for (final (oi, option) in q.options.indexed)
          _OptionRow(
            label: option.shownLabel,
            recommended: option.recommended,
            description: option.description,
            multiple: q.multiSelect,
            selected: answer.selected.contains(oi),
            shortcut: oi < 6 ? '${oi + 1}' : null,
            onTap: enabled ? () => onPick(oi) : null,
          ),
        _OtherRow(
          controller: other,
          focusNode: otherFocus,
          multiple: q.multiSelect,
          active: answer.other.trim().isNotEmpty,
          enabled: enabled,
          onChanged: onOther,
          onSubmitted: onOtherSubmitted,
          onAttach: enabled ? onAttach : null,
        ),
      ],
    );
  }
}

class _HeaderChip extends StatelessWidget {
  const _HeaderChip(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: theme.accent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(5)),
      child: Text(label, style: theme.type.footnote.medium.tint(theme.accent)),
    );
  }
}

/// A radio (round) or checkbox (square) choice with a label and description.
class _OptionRow extends StatefulWidget {
  const _OptionRow({
    required this.label,
    required this.description,
    required this.multiple,
    this.recommended = false,
    required this.selected,
    required this.onTap,
    this.shortcut,
  });

  final String label;
  final String description;
  final bool multiple;
  final bool selected;
  final VoidCallback? onTap;

  /// The agent's pick, shown as a small tag after the label.
  final bool recommended;

  /// The number key that picks it.
  final String? shortcut;

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
      label: [
        widget.label,
        if (widget.recommended) 'recommended',
        if (widget.description.isNotEmpty) widget.description,
      ].join('. '),
      excludeSemantics: true,
      child: MouseRegion(
        cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Motion.easeInOut,
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: selected
                  ? theme.accent.withValues(alpha: 0.10)
                  : _hover && widget.onTap != null
                  ? theme.hover
                  : null,
              border: Border.all(color: selected ? theme.accent : theme.border, width: selected ? 1.5 : 1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: ChoiceMark(multiple: widget.multiple, selected: selected),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          text: widget.label,
                          children: [
                            if (widget.recommended)
                              WidgetSpan(
                                alignment: PlaceholderAlignment.middle,
                                child: Padding(padding: const EdgeInsets.only(left: 8), child: _RecommendedTag()),
                              ),
                          ],
                        ),
                        style: theme.type.body.medium.tint(theme.text),
                      ),
                      if (widget.description.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            widget.description,
                            style: theme.type.callout.tint(theme.textSubtle).copyWith(height: 1.35),
                          ),
                        ),
                    ],
                  ),
                ),
                if (widget.shortcut case final key? when Host.isDesktop) ...[
                  const SizedBox(width: 10),
                  Padding(padding: const EdgeInsets.only(top: 2), child: Kbd(key)),
                ],
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
    required this.focusNode,
    required this.multiple,
    required this.active,
    required this.enabled,
    required this.onChanged,
    required this.onSubmitted,
    this.onAttach,
  });

  final VoidCallback? onAttach;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmitted;
  final bool multiple;
  final bool active;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Motion.easeInOut,
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      decoration: BoxDecoration(
        color: active ? theme.accent.withValues(alpha: 0.10) : null,
        border: Border.all(color: active ? theme.accent : theme.border, width: active ? 1.5 : 1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 9),
            child: SizedBox(
              width: 18,
              child: AdaptiveIcon(EveryIcon.newChat, size: 14, color: active ? theme.accent : theme.textSubtle),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: IgnorePointer(
              ignoring: !enabled,
              child: AdaptiveTextField(
                controller: controller,
                focusNode: focusNode,
                placeholder: 'Other',
                borderless: true,
                // Wraps and grows with a long answer; Enter still moves on (no newlines).
                minLines: 1,
                maxLines: 6,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.done,
                onChanged: onChanged,
                onSubmitted: (_) => onSubmitted(),
              ),
            ),
          ),
          if (onAttach != null)
            AdaptiveIconButton(
              icon: EveryIcon.attach,
              tooltip: 'Attach files',
              color: theme.textMuted,
              onPressed: onAttach,
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
        color: selected && multiple ? theme.primary : null,
        border: Border.all(color: selected ? theme.accent : theme.textMuted.withValues(alpha: 0.6), width: 1.5),
        borderRadius: BorderRadius.circular(multiple ? 4.5 : 9),
      ),
      child: !selected
          ? null
          : multiple
          ? AdaptiveIcon(EveryIcon.check, size: 12, color: theme.onPrimary)
          : Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: theme.accent, shape: BoxShape.circle),
            ),
    );
  }
}

class _Answered extends StatelessWidget {
  const _Answered({required this.questions, required this.answers, this.reply});

  final List<Question> questions;
  final List<QuestionAnswer> answers;
  final String? reply;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (answers.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          border: Border.all(color: theme.border),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              questions.length == 1 ? 'Question answered in chat' : '${questions.length} questions, answered in chat',
              style: theme.type.callout.tint(theme.textMuted),
            ),
            if (reply case final r? when r.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(r.trim(), style: theme.type.callout.tint(theme.text)),
            ],
          ],
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(16),
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
                  Text(q.question, style: theme.type.callout.tint(theme.textMuted)),
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
                              // A long typed answer wraps inside the chip instead of running off the card.
                              Flexible(child: Text(label, style: theme.type.callout.medium.tint(theme.text))),
                            ],
                          ),
                        ),
                      if (i >= answers.length || answers[i].isEmpty)
                        Text('Skipped', style: theme.type.callout.tint(theme.textMuted)),
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

/// "Recommended", after the label of the option the agent would pick.
class _RecommendedTag extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: theme.accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(5)),
      child: Text('Recommended', style: theme.type.micro.semibold.tint(theme.accent)),
    );
  }
}
