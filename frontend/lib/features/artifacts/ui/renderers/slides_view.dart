import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../domain/artifact.dart';

/// Colors of a deck theme (`make_slides.theme`).
@immutable
final class DeckTheme {
  const DeckTheme(this.background, this.title, this.text, this.accent);

  static DeckTheme of(String name) => switch (name) {
    'dark' => const DeckTheme(Color(0xFF16181D), Color(0xFFFFFFFF), Color(0xFFD5D8DE), Color(0xFF8B7CF6)),
    'navy' => const DeckTheme(Color(0xFF0F2547), Color(0xFFFFFFFF), Color(0xFFD6E2F5), Color(0xFF5FB3F9)),
    'minimal' => const DeckTheme(Color(0xFFFAFAF7), Color(0xFF111111), Color(0xFF333333), Color(0xFF111111)),
    _ => const DeckTheme(Color(0xFFFFFFFF), Color(0xFF1C1B22), Color(0xFF3A3A44), Color(0xFF6E56CF)),
  };

  final Color background;
  final Color title;
  final Color text;
  final Color accent;
}

@immutable
final class Slide {
  const Slide({required this.title, this.bullets = const [], this.body = '', this.notes = ''});
  final String title;
  final List<String> bullets;
  final String body;
  final String notes;
}

/// The deck in [visual]: a title slide, then the model's slides.
List<Slide> slidesOf(Visual visual) => [
  Slide(title: visual.title, body: visual.str('subtitle')),
  for (final s in (visual.args['slides'] as List<Object?>?) ?? const [])
    if (s case {'title': final String title})
      Slide(
        title: title,
        bullets: ((s['bullets'] as List<Object?>?) ?? const []).whereType<String>().toList(),
        body: s['body'] as String? ?? '',
        notes: s['notes'] as String? ?? '',
      ),
];

/// One 16:9 slide, laid out at 960×540 and scaled to fit.
class SlideCanvas extends StatelessWidget {
  const SlideCanvas({super.key, required this.slide, required this.theme, this.isTitle = false});

  final Slide slide;
  final DeckTheme theme;
  final bool isTitle;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: FittedBox(
        child: Container(
          width: 960,
          height: 540,
          color: theme.background,
          padding: const EdgeInsets.fromLTRB(64, 56, 64, 48),
          child: isTitle
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(width: 72, height: 6, color: theme.accent),
                    const SizedBox(height: 24),
                    Text(
                      slide.title,
                      style: TextStyle(color: theme.title, fontSize: 56, fontWeight: FontWeight.w800, height: 1.1),
                    ),
                    if (slide.body.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(slide.body, style: TextStyle(color: theme.text, fontSize: 26)),
                    ],
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      slide.title,
                      style: TextStyle(color: theme.title, fontSize: 40, fontWeight: FontWeight.w700, height: 1.15),
                    ),
                    const SizedBox(height: 10),
                    Container(width: 56, height: 4, color: theme.accent),
                    const SizedBox(height: 28),
                    for (final b in slide.bullets)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 12, right: 16),
                              child: Container(
                                width: 9,
                                height: 9,
                                decoration: BoxDecoration(color: theme.accent, shape: BoxShape.circle),
                              ),
                            ),
                            Expanded(
                              child: Text(b, style: TextStyle(color: theme.text, fontSize: 26, height: 1.35)),
                            ),
                          ],
                        ),
                      ),
                    if (slide.body.isNotEmpty)
                      Expanded(
                        child: Text(
                          // Slides show plain text; markdown markers would read as noise.
                          slide.body.replaceAll(RegExp(r'(\*\*|__|`|^#+\s*)', multiLine: true), ''),
                          style: TextStyle(color: theme.text, fontSize: 24, height: 1.4),
                          overflow: TextOverflow.fade,
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Slide deck viewer: arrows or buttons to move, speaker notes below.
class SlidesView extends StatefulWidget {
  const SlidesView({super.key, required this.visual, this.showNotes = true});

  final Visual visual;
  final bool showNotes;

  @override
  State<SlidesView> createState() => _SlidesViewState();
}

class _SlidesViewState extends State<SlidesView> {
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
    final slides = slidesOf(widget.visual);
    final deck = DeckTheme.of(widget.visual.str('theme'));
    final i = _index.clamp(0, slides.length - 1);
    final slide = slides[i];
    void go(int d) => setState(() => _index = (i + d).clamp(0, slides.length - 1));

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
                child: SlideCanvas(slide: slide, theme: deck, isTitle: i == 0),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              AdaptiveIconButton(icon: EveryIcon.chevronLeft, tooltip: 'Previous slide', onPressed: () => go(-1)),
              Text(
                '${i + 1} / ${slides.length}',
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
