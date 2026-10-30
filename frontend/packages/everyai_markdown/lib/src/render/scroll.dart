import 'package:flutter/widgets.dart';

/// A horizontal [SingleChildScrollView] with a thin, subtle scrollbar that
/// shows while the pointer hovers it (desktop) or while scrolling (touch).
///
/// The platform's default scrollbar is suppressed so only one is drawn.
class HorizontalScroller extends StatefulWidget {
  const HorizontalScroller({super.key, required this.child, required this.thumbColor, this.padding});

  final Widget child;
  final Color thumbColor;
  final EdgeInsetsGeometry? padding;

  @override
  State<HorizontalScroller> createState() => _HorizontalScrollerState();
}

class _HorizontalScrollerState extends State<HorizontalScroller> {
  final ScrollController _controller = ScrollController();
  bool _hovered = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setHovered(bool value) {
    if (_hovered != value) setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: RawScrollbar(
          controller: _controller,
          thumbVisibility: _hovered,
          thickness: 5,
          radius: const Radius.circular(3),
          thumbColor: widget.thumbColor,
          mainAxisMargin: 6,
          crossAxisMargin: 2,
          child: SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
