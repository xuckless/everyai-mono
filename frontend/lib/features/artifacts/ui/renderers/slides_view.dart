import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../artifact_providers.dart';
import '../../checks/webview_diagram_renderer.dart';
import '../../domain/artifact.dart';
import '../../domain/slide_pictures.dart';
import '../../domain/slide_spec.dart';
import 'slide_canvas.dart';

/// The pictures a deck shows, drawn once per set of references and redrawn when the chat's figures change (an
/// edit to a figure shows on every slide that uses it). Keyed by conversation and the pictures, one per line as
/// `ref<tab>argb` (the colour behind it).
final slideArtProvider = FutureProvider.autoDispose.family<SlideArtBook, (String, String)>((ref, key) async {
  final (conversationId, refs) = key;
  final sources = slideSourcesOf(ref.watch(conversationArtifactsProvider(conversationId)));
  final uses = [
    for (final line in refs.split('\n'))
      if (line.split('\t') case [final r, final on] when r.isNotEmpty) (ref: r, on: Color(int.parse(on))),
  ];
  final book = await drawSlideArt(uses, sources, diagrams: appDiagramRenderer);
  ref.onDispose(book.dispose);
  return book;
});

/// The art for [deck]: drawn pictures, or [SlideArtBook.pending] while they draw (or if drawing failed).
SlideArtBook watchSlideArt(WidgetRef ref, String conversationId, List<DeckSlide> deck) {
  final uses = pictureUsesOf(deck);
  if (uses.isEmpty) return SlideArtBook(const {});
  final key = [for (final u in uses) '${u.ref}\t${u.on.toARGB32()}'].join('\n');
  return switch (ref.watch(slideArtProvider((conversationId, key)))) {
    AsyncData(:final value) => value,
    AsyncError() || AsyncLoading() => SlideArtBook.pending(),
  };
}

/// A deck's first slide, small (the chat card).
class SlidePreview extends ConsumerWidget {
  const SlidePreview({super.key, required this.visual, required this.conversationId});

  final Visual visual;
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deck = deckOf(visual).take(1).toList();
    return SlideCanvas(slide: deck.first, art: watchSlideArt(ref, conversationId, deck));
  }
}

/// Slide deck viewer: arrows or buttons to move, speaker notes below.
class SlidesView extends ConsumerStatefulWidget {
  const SlidesView({super.key, required this.visual, required this.conversationId, this.showNotes = true});

  final Visual visual;
  final String conversationId;
  final bool showNotes;

  @override
  ConsumerState<SlidesView> createState() => _SlidesViewState();
}

class _SlidesViewState extends ConsumerState<SlidesView> {
  /// The slide shown (a position, not a lifecycle).
  int _index = 0;
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final deck = deckOf(widget.visual);
    final art = watchSlideArt(ref, widget.conversationId, deck);
    final i = _index.clamp(0, deck.length - 1);
    final slide = deck[i];
    void go(int d) => setState(() => _index = (i + d).clamp(0, deck.length - 1));

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (_, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.arrowRight || e.logicalKey == LogicalKeyboardKey.space) {
          go(1);
        } else if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
          go(-1);
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: () {
              _focus.requestFocus();
              go(1);
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(theme.radius),
              child: DecoratedBox(
                decoration: BoxDecoration(border: Border.all(color: theme.border)),
                child: SlideCanvas(slide: slide, art: art),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              AdaptiveIconButton(icon: EveryIcon.chevronLeft, tooltip: 'Previous slide', onPressed: () => go(-1)),
              Text(
                '${i + 1} / ${deck.length}',
                style: TextStyle(color: theme.textMuted, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              AdaptiveIconButton(icon: EveryIcon.chevronRight, tooltip: 'Next slide', onPressed: () => go(1)),
            ],
          ),
          if (widget.showNotes && slide.notes.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: theme.surfaceRaised, borderRadius: BorderRadius.circular(theme.radius)),
              child: Text('Notes: ${slide.notes}', style: TextStyle(color: theme.textMuted, fontSize: 13)),
            ),
        ],
      ),
    );
  }
}
