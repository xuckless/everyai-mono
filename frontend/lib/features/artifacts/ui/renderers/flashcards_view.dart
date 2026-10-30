import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../chat/ui/chat_markdown.dart';
import '../../domain/artifact.dart';

/// A deck of flip cards: tap (or space) to flip, arrows to move, and mark each
/// card "Got it" or "Still learning".
class FlashcardsView extends StatefulWidget {
  const FlashcardsView({super.key, required this.visual, this.height = 220});

  final Visual visual;
  final double height;

  @override
  State<FlashcardsView> createState() => _FlashcardsViewState();
}

class _FlashcardsViewState extends State<FlashcardsView> {
  int _index = 0;
  bool _flipped = false;
  final _known = <int>{};
  final _learning = <int>{};
  final _focus = FocusNode();

  List<(String, String)> get _cards => [
    for (final c in (widget.visual.args['cards'] as List<Object?>?) ?? const [])
      if (c case {'front': final String front, 'back': final String back}) (front, back),
  ];

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final n = _cards.length;
    if (n == 0) return;
    setState(() {
      _index = (_index + delta) % n;
      if (_index < 0) _index += n;
      _flipped = false;
    });
  }

  void _mark(bool known) {
    setState(() {
      (known ? _known : _learning).add(_index);
      (known ? _learning : _known).remove(_index);
    });
    _go(1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final cards = _cards;
    if (cards.isEmpty) return Text('No cards.', style: TextStyle(color: theme.textMuted));
    final (front, back) = cards[_index];

    return Focus(
      focusNode: _focus,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.space) {
          setState(() => _flipped = !_flipped);
        } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _go(1);
        } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _go(-1);
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
              setState(() => _flipped = !_flipped);
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: _flipped ? 1 : 0),
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeInOutCubic,
                builder: (context, t, _) {
                  final showBack = t > 0.5;
                  return Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.0012)
                      ..rotateY(math.pi * t + (showBack ? math.pi : 0)),
                    child: Container(
                      height: widget.height,
                      padding: const EdgeInsets.all(20),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: showBack ? theme.accent.withValues(alpha: 0.10) : theme.surfaceRaised,
                        borderRadius: BorderRadius.circular(theme.radius + 6),
                        border: Border.all(color: showBack ? theme.accent.withValues(alpha: 0.5) : theme.border),
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              showBack ? 'ANSWER' : 'QUESTION',
                              style: TextStyle(
                                color: theme.textMuted,
                                fontSize: 11,
                                letterSpacing: 1.2,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 10),
                            if (showBack)
                              ChatMarkdown(back)
                            else
                              Text(
                                front,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: theme.text, fontSize: 18, fontWeight: FontWeight.w600),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              AdaptiveIconButton(icon: EveryIcon.chevronLeft, tooltip: 'Previous card', onPressed: () => _go(-1)),
              Text(
                '${_index + 1} / ${cards.length}',
                style: TextStyle(color: theme.textMuted, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              AdaptiveIconButton(icon: EveryIcon.chevronRight, tooltip: 'Next card', onPressed: () => _go(1)),
              const Spacer(),
              Text(
                '${_known.length} known · ${_learning.length} learning',
                style: TextStyle(color: theme.textMuted, fontSize: 12),
              ),
              const SizedBox(width: 10),
              AdaptiveButton(label: 'Still learning', emphasis: ButtonEmphasis.plain, onPressed: () => _mark(false)),
              AdaptiveButton(label: 'Got it', emphasis: ButtonEmphasis.secondary, onPressed: () => _mark(true)),
            ],
          ),
        ],
      ),
    );
  }
}
