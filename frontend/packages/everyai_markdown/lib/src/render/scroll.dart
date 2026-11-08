import 'package:flutter/widgets.dart';

/// Markdown laid out for a still picture (a page someone looks at, not
/// scrolls): blocks that scroll sideways in the app are shrunk to fit the
/// width instead, and code wraps, so nothing is cut off at the edge.
class StillLayout extends InheritedWidget {
  const StillLayout({super.key, required super.child});

  /// Whether [context] is laid out for a still picture.
  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<StillLayout>() != null;

  @override
  bool updateShouldNotify(StillLayout oldWidget) => false;
}

/// A horizontal [SingleChildScrollView] with a thin, subtle scrollbar that
/// shows while the pointer hovers it (desktop) or while scrolling (touch).
/// Under a [StillLayout] it shrinks its child to fit instead.
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
    if (StillLayout.of(context)) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: widget.padding == null ? widget.child : Padding(padding: widget.padding!, child: widget.child),
      );
    }
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
