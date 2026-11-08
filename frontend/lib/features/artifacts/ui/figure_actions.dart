import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../chat/chat_providers.dart';
import '../artifact_providers.dart';
import '../domain/artifact.dart';
import '../domain/svg_parts.dart';
import 'renderers/svg_view.dart';

/// What a figure card is doing: showing the figure, or waiting for the user to click the part to ask about.
enum FigureCardMode { viewing, picking }

/// Each figure card's mode, by the call that made it.
final figureCardModeProvider = NotifierProvider.autoDispose.family<FigureCardModeNotifier, FigureCardMode, String>(
  FigureCardModeNotifier.new,
);

final class FigureCardModeNotifier extends Notifier<FigureCardMode> {
  FigureCardModeNotifier(this.callId);
  final String callId;

  @override
  FigureCardMode build() => FigureCardMode.viewing;

  void pick() => state = FigureCardMode.picking;
  void view() => state = FigureCardMode.viewing;
}

/// Text waiting to go into a chat's composer (point and ask), by conversation: null when none. The chat screen
/// takes it into the box (never sends it).
final composerInsertProvider = NotifierProvider.family<ComposerInsert, String?, String>(ComposerInsert.new);

final class ComposerInsert extends Notifier<String?> {
  ComposerInsert(this.conversationId);
  final String conversationId;

  @override
  String? build() => null;

  void offer(String text) => state = text;

  /// The waiting text, now handed over.
  String? take() {
    final text = state;
    state = null;
    return text;
  }
}

/// The ⋯ menu on a figure's card: point at a part and ask about it, edit its colours and text by hand (SVG), or
/// put it into one of the chat's documents or decks (as a new version the user made; the model sees it next turn).
class FigureMenu extends ConsumerWidget {
  const FigureMenu({super.key, required this.visual, required this.figureId, required this.conversationId});

  final Visual visual;
  final String figureId;
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artifacts = ref.watch(conversationArtifactsProvider(conversationId));
    final docs = [
      for (final a in artifacts)
        if (a.latest.kind == VisualKind.document && a.latest.str('content').isNotEmpty) a,
    ];
    final decks = [
      for (final a in artifacts)
        if (a.latest.kind == VisualKind.slides) a,
    ];
    final isSvg = visual.kind == VisualKind.svg;
    return AdaptiveMenuButton(
      tooltip: 'Figure actions',
      width: 300,
      actions: [
        if (isSvg)
          MenuAction(
            label: 'Point and ask',
            icon: EveryIcon.eye,
            onSelected: () => ref.read(figureCardModeProvider(visual.callId).notifier).pick(),
          ),
        if (isSvg)
          MenuAction(label: 'Edit colours and text', icon: EveryIcon.edit, onSelected: () => _editByHand(context, ref)),
        for (final d in docs)
          MenuAction(
            label: 'Insert into “${d.title}”',
            icon: EveryIcon.document,
            onSelected: () => _insertIntoDocument(context, ref, d),
          ),
        for (final d in decks)
          MenuAction(
            label: 'Add as a slide to “${d.title}”',
            icon: EveryIcon.document,
            onSelected: () => _addSlide(context, ref, d),
          ),
      ],
      child: AdaptiveIcon(EveryIcon.more, size: 18, color: EveryTheme.of(context).textMuted),
    );
  }

  Future<void> _save(BuildContext context, WidgetRef ref, Map<String, Object?> args, String done) async {
    final saved = await ref
        .read(chatSessionProvider(conversationId).notifier)
        .saveUserArtifact('update_artifact', args);
    if (!context.mounted) return;
    showAdaptiveToast(context, saved ? done : 'Wait for the answer to finish, then try again.');
  }

  Future<void> _insertIntoDocument(BuildContext context, WidgetRef ref, Artifact doc) => _save(context, ref, {
    'id': doc.id,
    'content': '${doc.latest.str('content').trimRight()}\n\n![${visual.title}](figure:$figureId)\n',
  }, 'Added to “${doc.title}”');

  Future<void> _addSlide(BuildContext context, WidgetRef ref, Artifact deck) {
    final args = {
      for (final e in deck.latest.args.entries)
        if (!const {'id', 'kind', 'content', 'edited_by', 'edit_missed', 'edits'}.contains(e.key)) e.key: e.value,
    };
    final slides = [...?(args['slides'] as List<Object?>?)];
    slides.add({'title': visual.title, 'layout': 'figure', 'figure': figureId});
    return _save(context, ref, {
      'id': deck.id,
      'content': jsonEncode({...args, 'slides': slides}),
    }, 'Added a slide to “${deck.title}”');
  }

  Future<void> _editByHand(BuildContext context, WidgetRef ref) async {
    final svg = visual.args['svg'] as String? ?? visual.str('content');
    final edited = await showKitDialog<String>(
      context,
      builder: (_) => _FigureEditor(svg: svg, title: visual.title),
    );
    if (edited == null || edited == svg || !context.mounted) return;
    await _save(context, ref, {'id': figureId, 'content': edited}, 'Saved a new version');
  }
}

/// The figure, with the part under the pointer outlined; a click puts "In figure `id`, `part`: " in the composer
/// and goes back to viewing.
class FigurePicker extends ConsumerStatefulWidget {
  const FigurePicker({
    super.key,
    required this.svg,
    required this.figureId,
    required this.callId,
    required this.conversationId,
  });

  final String svg;
  final String figureId;
  final String callId;
  final String conversationId;

  @override
  ConsumerState<FigurePicker> createState() => _FigurePickerState();
}

class _FigurePickerState extends ConsumerState<FigurePicker> {
  late List<SvgPart> _parts = svgParts(widget.svg);
  late Rect? _box = svgViewBox(widget.svg);

  /// The part under the pointer (a hover highlight, not a lifecycle).
  SvgPart? _hover;

  @override
  void didUpdateWidget(FigurePicker old) {
    super.didUpdateWidget(old);
    if (old.svg != widget.svg) {
      _parts = svgParts(widget.svg);
      _box = svgViewBox(widget.svg);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final box = _box;
    void done() => ref.read(figureCardModeProvider(widget.callId).notifier).view();
    final hint = Row(
      children: [
        Expanded(
          child: Text(
            _hover == null ? 'Click a part of the figure to ask about it' : 'Ask about ${_hover!.label}',
            style: theme.type.callout.tint(theme.textMuted),
          ),
        ),
        AdaptiveButton(label: 'Done', emphasis: ButtonEmphasis.secondary, onPressed: done),
      ],
    );
    if (box == null) {
      return Column(
        children: [
          hint,
          SvgView(svg: widget.svg, maxHeight: 420),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        hint,
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: AspectRatio(
            aspectRatio: box.width / box.height,
            child: LayoutBuilder(
              builder: (context, c) {
                final scale = c.maxWidth / box.width;
                Offset toFigure(Offset p) => Offset(box.left + p.dx / scale, box.top + p.dy / scale);
                final hover = _hover;
                return MouseRegion(
                  cursor: SystemMouseCursors.precise,
                  onHover: (e) => setState(() => _hover = partAt(_parts, toFigure(e.localPosition))),
                  onExit: (_) => setState(() => _hover = null),
                  child: GestureDetector(
                    onTapUp: (e) {
                      final part = partAt(_parts, toFigure(e.localPosition));
                      if (part == null) return;
                      final what = part.id == null
                          ? part.label
                          : (part.label == '#${part.id}' ? '#${part.id}' : '#${part.id} (${part.label})');
                      ref
                          .read(composerInsertProvider(widget.conversationId).notifier)
                          .offer('In figure ${widget.figureId}, $what: ');
                      done();
                    },
                    child: Stack(
                      children: [
                        Positioned.fill(child: SvgPicture.string(sanitizeSvg(widget.svg), fit: BoxFit.fill)),
                        if (hover != null)
                          Positioned(
                            left: (hover.box.left - box.left) * scale - 2,
                            top: (hover.box.top - box.top) * scale - 2,
                            width: hover.box.width * scale + 4,
                            height: hover.box.height * scale + 4,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border.all(color: theme.accent, width: 2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// Hand edits without the model: the figure's colours (each one, wherever it is used) and its text lines. Pops
/// with the edited SVG, or null.
class _FigureEditor extends StatefulWidget {
  const _FigureEditor({required this.svg, required this.title});

  final String svg;
  final String title;

  @override
  State<_FigureEditor> createState() => _FigureEditorState();
}

class _FigureEditorState extends State<_FigureEditor> {
  late final _colours = {for (final c in svgColours(widget.svg).take(12)) c: TextEditingController(text: c)};
  late final _texts = [for (final t in svgTexts(widget.svg)) TextEditingController(text: t)];

  @override
  void dispose() {
    for (final c in [..._colours.values, ..._texts]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _edited => editSvg(
    widget.svg,
    colours: {
      for (final e in _colours.entries)
        if (RegExp(r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$').hasMatch(e.value.text.trim()) &&
            e.value.text.trim().toLowerCase() != e.key)
          e.key: e.value.text.trim().toLowerCase(),
    },
    texts: {
      for (final (i, c) in _texts.indexed)
        if (c.text != svgTexts(widget.svg)[i]) i: c.text,
    },
  );

  Color _swatch(String hex) {
    final h = hex.substring(1);
    final full = h.length == 3 ? h.split('').map((c) => '$c$c').join() : h;
    return Color(0xFF000000 | (int.tryParse(full, radix: 16) ?? 0));
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return KitDialog(
      title: 'Edit “${widget.title}”',
      width: 560,
      body: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 520),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: 180, child: SvgPicture.string(sanitizeSvg(_edited), fit: BoxFit.contain)),
              const SizedBox(height: 12),
              if (_colours.isNotEmpty) ...[
                Text('Colours', style: theme.type.callout.semibold.tint(theme.text)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final e in _colours.entries)
                      SizedBox(
                        width: 160,
                        child: Row(
                          children: [
                            ValueListenableBuilder(
                              valueListenable: e.value,
                              builder: (_, v, _) => Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: RegExp(r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$').hasMatch(v.text.trim())
                                      ? _swatch(v.text.trim())
                                      : _swatch(e.key),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: theme.border),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: AdaptiveTextField(controller: e.value, onChanged: (_) => setState(() {})),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              if (_texts.isNotEmpty) ...[
                Text('Text', style: theme.type.callout.semibold.tint(theme.text)),
                const SizedBox(height: 6),
                for (final c in _texts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: AdaptiveTextField(controller: c, onChanged: (_) => setState(() {})),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        KitButton(label: 'Cancel', style: KitButtonStyle.ghost, onPressed: () => Navigator.of(context).pop()),
        KitButton(label: 'Save', onPressed: () => Navigator.of(context).pop(_edited)),
      ],
    );
  }
}
