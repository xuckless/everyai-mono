import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../style.dart';

/// Builds the widget for a TeX expression.
///
/// [display] is true for display math (`$$...$$`, `\[...\]`, ```math
/// fences) and false for inline math (`$...$`, `\(...\)`). The surrounding
/// text style is available through `DefaultTextStyle.of(context)` inside the
/// returned widget's own build.
typedef MathBuilder = Widget Function(BuildContext context, String tex, {required bool display});

/// The default [MathBuilder], rendering with flutter_math_fork.
///
/// When the expression fails to parse (for example while it is still being
/// streamed) the raw TeX is shown in the inline-code style instead.
Widget defaultMathBuilder(BuildContext context, String tex, {required bool display}) =>
    _TexView(tex: tex, display: display);

class _TexView extends StatelessWidget {
  const _TexView({required this.tex, required this.display});

  final String tex;
  final bool display;

  @override
  Widget build(BuildContext context) {
    final ambient = DefaultTextStyle.of(context).style;
    final textStyle = ambient.copyWith(
      fontSize: ambient.fontSize ?? 14,
      color: ambient.color ?? const Color(0xFF000000),
    );
    final codeStyle = MarkdownStyle.maybeOf(context)?.inlineCode ?? const TextStyle(fontFamily: 'monospace');
    return _DryBaseline(
      fontSize: textStyle.fontSize!,
      child: Math.tex(
        tex,
        mathStyle: display ? MathStyle.display : MathStyle.text,
        textStyle: textStyle,
        onErrorFallback: (error) => Text(tex, style: textStyle.merge(codeStyle)),
      ),
    );
  }
}

/// Answers dry-baseline queries for flutter_math_fork, whose RenderLine
/// doesn't implement them. Measuring a paragraph that holds inline math
/// (table columns sized to their content, IntrinsicWidth) asks for one, and
/// the unanswered query fails layout on every frame. The estimate only
/// affects measuring; real layout uses the true baseline.
class _DryBaseline extends SingleChildRenderObjectWidget {
  const _DryBaseline({required this.fontSize, required super.child});

  final double fontSize;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderDryBaseline(fontSize);

  @override
  void updateRenderObject(BuildContext context, _RenderDryBaseline renderObject) => renderObject.fontSize = fontSize;
}

class _RenderDryBaseline extends RenderProxyBox {
  _RenderDryBaseline(this.fontSize);

  double fontSize;

  @override
  double? computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) {
    final child = this.child;
    if (child == null) return null;
    final height = child.getDryLayout(constraints).height;
    // About a quarter of the font size sits below the baseline.
    return (height - fontSize * 0.25).clamp(0, height);
  }
}
