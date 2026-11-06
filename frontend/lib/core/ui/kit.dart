import 'package:flutter/widgets.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:material_ui/material_ui.dart' as m show Tooltip;

import '../motion/motion.dart';
import '../theme/every_theme.dart';
import 'every_icons.dart';

/// The EveryAI kit: the controls every screen is built from, one look on every
/// platform (see the "EveryAI" design artifact). Motion comes from [Motion].

enum KitButtonStyle { primary, soft, ghost, danger }

/// A text button: 32pt (44pt when [large]), r9, scales to 0.97 on press.
/// [done] fills it green from the leading edge, swaps the label for a check
/// and pulses, for actions that confirm (Allow, Approve).
class KitButton extends StatelessWidget {
  const KitButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.style = KitButtonStyle.primary,
    this.icon,
    this.leading,
    this.large = false,
    this.expand = false,
    this.busy = false,
    this.shortcut,
    this.done = false,
    this.doneLabel = 'Done',
  });

  final String label;
  final VoidCallback? onPressed;
  final KitButtonStyle style;
  final EveryIcon? icon;

  /// A custom widget before the label, in place of [icon].
  final Widget? leading;
  final bool large;
  final bool expand;
  final bool busy;

  /// A key hint drawn after the label (⌘↵, esc).
  final String? shortcut;
  final bool done;
  final String doneLabel;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final enabled = onPressed != null && !busy;
    final (bg, hoverBg, fg) = switch (style) {
      KitButtonStyle.primary => (theme.primary, theme.primaryHover, theme.onPrimary),
      KitButtonStyle.soft => (theme.surfaceRaised, theme.overlay, theme.text),
      KitButtonStyle.ghost => (null, theme.hover, theme.text),
      KitButtonStyle.danger => (null, theme.dangerBg, theme.danger),
    };
    final height = large ? 44.0 : 32.0;
    final radius = large ? 12.0 : 9.0;
    final text = (large ? theme.type.body : theme.type.callout).medium.copyWith(height: 1.2);
    final doneFg = theme.isDark ? const Color(0xFF05210F) : const Color(0xFFFFFFFF);

    Widget labelRow(String label, {bool check = false, required Color color}) => Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (check) ...[Icon(EveryIcon.check.data, size: 16, color: color), const SizedBox(width: 6)],
        if (!check && leading != null) ...[leading!, const SizedBox(width: 8)],
        if (!check && leading == null && icon != null) ...[
          Icon(icon!.data, size: 16, color: color),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.tint(color)),
        ),
        if (!check && shortcut != null) ...[
          const SizedBox(width: 8),
          Kbd(shortcut!, onFilled: style == KitButtonStyle.primary),
        ],
      ],
    );

    final content = busy
        ? SizedBox.square(dimension: 14, child: KitSpinner(color: fg))
        : StateSwap(
            alignment: Alignment.center,
            child: done
                ? KeyedSubtree(
                    key: const ValueKey('done'),
                    child: labelRow(doneLabel, check: true, color: doneFg),
                  )
                : KeyedSubtree(
                    key: const ValueKey('label'),
                    child: labelRow(label, color: enabled ? fg : fg.withValues(alpha: 0.5)),
                  ),
          );

    Widget button = Pressable(
      onTap: enabled && !done ? onPressed : null,
      semanticLabel: label,
      builder: (context, s, child) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: height,
        padding: EdgeInsets.symmetric(horizontal: large ? 16 : 12),
        decoration: BoxDecoration(
          color: s.hovered ? hoverBg : bg,
          borderRadius: BorderRadius.circular(radius),
          border: style == KitButtonStyle.soft ? Border.all(color: theme.border) : null,
        ),
        child: MaskFill(
          filled: done,
          color: theme.success,
          radius: radius,
          child: Center(widthFactor: 1, child: child),
        ),
      ),
      child: content,
    );
    button = SuccessPulse(trigger: done ? true : null, radius: radius, color: theme.success, child: button);
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// A square icon button: 32pt on desktop, 44pt on touch.
class KitIconButton extends StatelessWidget {
  const KitIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.touch = false,
    this.color,
    this.size,
    this.round = false,
    this.selected = false,
    this.child,
  });

  final EveryIcon icon;

  /// Drawn in place of [icon] (an [IconSwap] between two glyphs).
  final Widget? child;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool touch;
  final Color? color;
  final double? size;
  final bool round;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final box = touch ? 44.0 : 32.0;
    return m.Tooltip(message: tooltip, child: _button(theme, box));
  }

  Widget _button(EveryTheme theme, double box) {
    return Pressable(
      onTap: onPressed,
      selected: selected,
      builder: (context, s, child) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: box,
        height: box,
        decoration: BoxDecoration(
          color: s.pressed
              ? theme.pressed
              : s.hovered || selected
              ? theme.hover
              : null,
          borderRadius: BorderRadius.circular(round ? box : (touch ? 12 : 9)),
        ),
        alignment: Alignment.center,
        child: IconTheme.merge(
          data: IconThemeData(color: color ?? (s.hovered || selected ? theme.text : theme.textMuted)),
          child: child,
        ),
      ),
      child: IconTheme.merge(
        data: IconThemeData(size: size ?? (touch ? 20 : 16)),
        child: child ?? Icon(icon.data, size: size ?? (touch ? 20 : 16)),
      ),
    );
  }
}

/// A compact pill: the model and mode pickers, file chips, filters.
class KitChip extends StatelessWidget {
  const KitChip({
    super.key,
    required this.label,
    this.onTap,
    this.leading,
    this.trailing,
    this.on = false,
    this.mono = false,
    this.touch = false,
    this.strong = false,
    this.chevron = false,
    this.tint,
  });

  final String label;

  /// A colour for the label at rest (a risky mode in red).
  final Color? tint;
  final VoidCallback? onTap;
  final Widget? leading;
  final Widget? trailing;
  final bool on;
  final bool mono;
  final bool touch;

  /// Text colour instead of muted (the current model).
  final bool strong;

  /// A small down chevron after the label (opens a menu).
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final style = mono ? theme.type.caption.mono : theme.type.callout;
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      selected: on,
      builder: (context, s, child) {
        final fg = on ? theme.accentText : tint ?? (s.hovered || strong ? theme.text : theme.textMuted);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: touch ? 36 : 30,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: on ? theme.accentBg : (s.hovered ? theme.hover : null),
            borderRadius: BorderRadius.circular(touch ? 99 : 9),
          ),
          child: IconTheme.merge(
            data: IconThemeData(color: fg, size: 14),
            child: DefaultTextStyle.merge(
              style: style.tint(fg),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 7)],
                  Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (trailing != null) ...[const SizedBox(width: 6), trailing!],
                  if (chevron) ...[
                    const SizedBox(width: 4),
                    Icon(EveryIcon.chevronDown.data, size: 13, color: theme.textSubtle),
                  ],
                ],
              ),
            ),
          ),
        );
      },
      child: const SizedBox.shrink(),
    );
  }
}

/// Segmented control with one indicator that slides between options
/// (ease-in-out, 280ms): Chat | Code, theme, effort, board filters.
class KitSegmented<T> extends StatelessWidget {
  const KitSegmented({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
    this.touch = false,
    this.icon,
    this.enabled,
    this.semanticLabel,
    this.width,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onSelected;
  final bool touch;
  final EveryIcon Function(T)? icon;
  final bool Function(T)? enabled;
  final String Function(T)? semanticLabel;

  /// Fixed width; null sizes each option to an equal share of its intrinsic widest.
  final double? width;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final index = values.indexOf(selected);
    final height = touch ? 34.0 : 28.0;
    Widget option(T v) {
      final on = v == selected;
      final can = enabled?.call(v) ?? true;
      final text = label(v);
      final glyph = icon?.call(v);
      return Pressable(
        key: ValueKey('segment.$v'),
        onTap: can && !on ? () => onSelected(v) : null,
        scale: false,
        selected: on,
        semanticLabel: semanticLabel?.call(v) ?? (text.isEmpty ? null : text),
        child: SizedBox(
          height: height,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: text.isEmpty ? 8 : 12),
            child: Center(
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: (touch ? theme.type.body : theme.type.callout).medium.copyWith(
                  height: 1.2,
                  color: !can
                      ? theme.textSubtle.withValues(alpha: 0.5)
                      : on
                      ? theme.text
                      : theme.textSubtle,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (glyph != null) Icon(glyph.data, size: 14, color: on ? theme.text : theme.textSubtle),
                    if (glyph != null && text.isNotEmpty) const SizedBox(width: 6),
                    if (text.isNotEmpty) Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final track = Container(
      width: width,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: theme.border),
      ),
      child: Stack(
        children: [
          if (index >= 0)
            Positioned.fill(
              child: _SlidingIndicator(
                count: values.length,
                index: index,
                color: theme.isDark ? theme.overlay : theme.surface,
                shadow: theme.shadowSoft,
              ),
            ),
          if (width != null)
            Row(children: [for (final v in values) Expanded(child: option(v))])
          else
            IntrinsicWidth(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [for (final v in values) Expanded(child: option(v))],
              ),
            ),
        ],
      ),
    );
    return Semantics(container: true, child: track);
  }
}

class _SlidingIndicator extends StatelessWidget {
  const _SlidingIndicator({required this.count, required this.index, required this.color, required this.shadow});
  final int count;
  final int index;
  final Color color;
  final List<BoxShadow> shadow;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final w = box.maxWidth / count;
      return Stack(
        children: [
          AnimatedPositioned(
            duration: Motion.move,
            curve: Motion.easeInOut,
            left: w * index,
            top: 0,
            bottom: 0,
            width: w,
            child: DecoratedBox(
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8), boxShadow: shadow),
            ),
          ),
        ],
      );
    },
  );
}

/// On/off switch. The knob stretches 12% at the middle of its travel.
class KitSwitch extends StatefulWidget {
  const KitSwitch({super.key, required this.value, required this.onChanged, this.semanticLabel});

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  State<KitSwitch> createState() => _KitSwitchState();
}

class _KitSwitchState extends State<KitSwitch> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    value: widget.value ? 1 : 0,
  );

  @override
  void didUpdateWidget(KitSwitch old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) {
      Motion.reduced(context)
          ? _c.value = widget.value ? 1 : 0
          : _c.animateTo(widget.value ? 1 : 0, curve: Motion.easeInOut);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Semantics(
      toggled: widget.value,
      label: widget.semanticLabel,
      child: Pressable(
        onTap: widget.onChanged == null ? null : () => widget.onChanged!(!widget.value),
        scale: false,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _c.value;
            // Stretch peaks mid-travel: 20 → 22.4 wide.
            final stretch = 1 + Motion.knobStretch * (1 - (2 * t - 1).abs());
            final knobW = 20 * stretch;
            final left = 3 + (44 - 6 - knobW) * t;
            return Container(
              width: 44,
              height: 26,
              decoration: BoxDecoration(
                color: Color.lerp(theme.borderStrong, theme.primary, t),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Stack(
                children: [
                  Positioned(
                    left: left,
                    top: 3,
                    child: Container(
                      width: knobW,
                      height: 20,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFFFFF),
                        borderRadius: BorderRadius.circular(99),
                        boxShadow: const [BoxShadow(color: Color(0x4D000000), blurRadius: 3, offset: Offset(0, 1))],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Surface box with a hairline ring (the kit's `.card`).
class KitCard extends StatelessWidget {
  const KitCard({super.key, required this.child, this.padding, this.color, this.radius = EveryTheme.cardRadius});

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color? color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? theme.surface,
        borderRadius: BorderRadius.circular(radius),
        border: theme.hairline,
      ),
      child: child,
    );
  }
}

/// Recessed box (the kit's `.well`): diffs, terminals, search fields.
class KitWell extends StatelessWidget {
  const KitWell({super.key, required this.child, this.padding, this.color});

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? theme.well,
        borderRadius: BorderRadius.circular(12),
        border: theme.hairline,
      ),
      child: child,
    );
  }
}

enum DotStatus { running, waiting, done, failed, idle }

/// A 7pt status dot; running breathes.
class StatusDot extends StatelessWidget {
  const StatusDot(this.status, {super.key, this.size = 7});

  final DotStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final color = switch (status) {
      DotStatus.running => theme.cyan,
      DotStatus.waiting => theme.warning,
      DotStatus.done => theme.success,
      DotStatus.failed => theme.danger,
      DotStatus.idle => null,
    };
    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: color == null ? Border.all(color: theme.textSubtle, width: 1.5) : null,
      ),
    );
    if (status != DotStatus.running || !Motion.loops(context)) return dot;
    return dot
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .fade(begin: 1, end: 0.35, duration: const Duration(milliseconds: 900), curve: Curves.easeInOut);
  }
}

/// A harness or vendor monogram: coloured square, white letters (CC, CX, EA).
class AgentGlyph extends StatelessWidget {
  const AgentGlyph({super.key, required this.letters, required this.color, this.size = 18});

  final String letters;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final fontSize = size * (letters.length > 1 ? 0.42 : 0.55);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(size * 0.3)),
      child: Text(
        letters,
        style: theme.type.micro.copyWith(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: const Color(0xFFFFFFFF),
          height: 1,
        ),
      ),
    );
  }
}

/// A keyboard hint (⌘K, esc).
class Kbd extends StatelessWidget {
  const Kbd(this.keys, {super.key, this.onFilled = false});

  final String keys;

  /// Drawn on a filled (primary) button.
  final bool onFilled;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final color = onFilled ? const Color(0xBFFFFFFF) : theme.textSubtle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: onFilled ? const Color(0x40FFFFFF) : theme.borderStrong),
      ),
      child: Text(keys, style: theme.type.footnote.mono.copyWith(fontSize: 11, color: color, height: 1.3)),
    );
  }
}

/// Text with a light sweeping across it (Thinking, Writing src/…).
class ShimmerText extends StatelessWidget {
  const ShimmerText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final base = (style ?? theme.type.callout).tint(theme.textSubtle);
    if (!Motion.loops(context)) return Text(text, style: base);
    return Text(text, style: base)
        .animate(onPlay: (c) => c.repeat())
        .shimmer(duration: const Duration(milliseconds: 2200), color: theme.text, angle: 0);
  }
}

/// A small arc spinner in the current text colour.
class KitSpinner extends StatelessWidget {
  const KitSpinner({super.key, this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final c = color ?? theme.textSubtle;
    if (!Motion.loops(context)) return CustomPaint(painter: _ArcPainter(c));
    return CustomPaint(painter: _ArcPainter(c))
        .animate(onPlay: (a) => a.repeat())
        .rotate(duration: const Duration(milliseconds: 900), begin: 0, end: 1);
  }
}

class _ArcPainter extends CustomPainter {
  const _ArcPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide / 8;
    final rect = Offset.zero & size;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect.deflate(stroke / 2), 0, 4.4, false, paint);
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.color != color;
}

/// A row in a menu or list: 34pt (48pt on touch), r9, hover fill.
class MenuRow extends StatelessWidget {
  const MenuRow({
    super.key,
    required this.child,
    this.onTap,
    this.leading,
    this.trailing,
    this.selected = false,
    this.touch = false,
    this.destructive = false,
    this.padding,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Widget? leading;
  final Widget? trailing;
  final bool selected;
  final bool touch;
  final bool destructive;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final style = (touch ? theme.type.body.copyWith(fontSize: 15) : theme.type.callout).tint(
      destructive ? theme.danger : (onTap == null ? theme.textSubtle : theme.text),
    );
    return Pressable(
      onTap: onTap,
      selected: selected,
      builder: (context, s, child) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        constraints: BoxConstraints(minHeight: touch ? 48 : 34),
        padding: padding ?? EdgeInsets.symmetric(horizontal: touch ? 12 : 10, vertical: touch ? 8 : 6),
        decoration: BoxDecoration(
          color: s.pressed
              ? theme.pressed
              : s.hovered || selected
              ? theme.hover
              : null,
          borderRadius: BorderRadius.circular(touch ? 12 : 9),
        ),
        child: child,
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: destructive ? theme.danger : theme.textMuted, size: touch ? 20 : 16),
        child: DefaultTextStyle.merge(
          style: style,
          child: Row(
            children: [
              if (leading != null) ...[leading!, SizedBox(width: touch ? 12 : 10)],
              Expanded(child: child),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

/// A quiet group label (12pt, medium, subtle; never upper case).
class KitLabel extends StatelessWidget {
  const KitLabel(this.text, {super.key, this.padding = const EdgeInsets.fromLTRB(10, 16, 10, 6)});

  final String text;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Padding(
      padding: padding,
      child: Text(text, style: theme.type.caption.medium.tint(theme.textSubtle)),
    );
  }
}

/// A row of text tabs with one underline that slides to the picked tab (the
/// same element moves; it is never drawn twice).
class KitTabs<T> extends StatefulWidget {
  const KitTabs({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
    this.keyOf,
    this.leading,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onSelected;

  /// A small mark before a tab's label (a status dot, a tick).
  final Widget Function(T)? leading;

  /// A key per tab (tests find tabs by it).
  final Key Function(T)? keyOf;

  @override
  State<KitTabs<T>> createState() => _KitTabsState<T>();
}

class _KitTabsState<T> extends State<KitTabs<T>> {
  final _row = GlobalKey();
  late List<GlobalKey> _keys = [for (final _ in widget.values) GlobalKey()];
  Rect? _bar;

  @override
  void didUpdateWidget(KitTabs<T> old) {
    super.didUpdateWidget(old);
    if (old.values.length != widget.values.length) _keys = [for (final _ in widget.values) GlobalKey()];
  }

  void _measure() {
    final i = widget.values.indexOf(widget.selected);
    final row = _row.currentContext?.findRenderObject() as RenderBox?;
    final tab = i < 0 ? null : _keys[i].currentContext?.findRenderObject() as RenderBox?;
    if (row == null || tab == null || !tab.hasSize) return;
    final at = tab.localToGlobal(Offset.zero, ancestor: row);
    final rect = Rect.fromLTWH(at.dx + 8, 0, tab.size.width - 16, 0);
    if (rect != _bar && mounted) setState(() => _bar = rect);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    final first = _bar == null;
    return Stack(
      key: _row,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, v) in widget.values.indexed)
              Pressable(
                key: widget.keyOf?.call(v),
                onTap: () => widget.onSelected(v),
                semanticLabel: widget.label(v),
                child: Padding(
                  key: _keys[i],
                  padding: const EdgeInsets.fromLTRB(8, 9, 8, 10),
                  child: AnimatedDefaultTextStyle(
                    duration: Motion.swap,
                    curve: Motion.easeOut,
                    style: theme.type.callout.medium.tint(v == widget.selected ? theme.text : theme.textSubtle),
                    child: widget.leading == null
                        ? Text(widget.label(v))
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(width: 12, child: Center(child: widget.leading!(v))),
                              const SizedBox(width: 7),
                              Text(widget.label(v)),
                            ],
                          ),
                  ),
                ),
              ),
          ],
        ),
        if (_bar case final bar?)
          AnimatedPositioned(
            duration: first ? Duration.zero : Motion.move,
            curve: Motion.easeInOut,
            left: bar.left,
            width: bar.width,
            bottom: 0,
            height: 2,
            child: DecoratedBox(
              decoration: BoxDecoration(color: theme.accent, borderRadius: BorderRadius.circular(1)),
            ),
          ),
      ],
    );
  }
}

/// Quiet text (an optional icon, a chevron) that lights up under the pointer to show it opens a menu: the parts of
/// the line under a composer. A popover around it takes the tap.
class QuietTrigger extends StatefulWidget {
  const QuietTrigger({super.key, this.label = '', this.icon, this.enabled = true, this.chevron = true});

  final String label;
  final EveryIcon? icon;
  final bool enabled;
  final bool chevron;

  @override
  State<QuietTrigger> createState() => _QuietTriggerState();
}

class _QuietTriggerState extends State<QuietTrigger> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final lit = _hover && widget.enabled;
    final color = lit ? theme.text : theme.textSubtle;
    return MouseRegion(
      cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(color: lit ? theme.hover : null, borderRadius: BorderRadius.circular(6)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.icon case final icon?) ...[
              Icon(icon.data, size: 13, color: color),
              if (widget.label.isNotEmpty) const SizedBox(width: 5),
            ],
            if (widget.label.isNotEmpty)
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.caption.tint(color),
                ),
              ),
            if (widget.chevron && widget.enabled) ...[
              const SizedBox(width: 3),
              Icon(EveryIcon.chevronDown.data, size: 10, color: color),
            ],
          ],
        ),
      ),
    );
  }
}

/// Rows that belong together on one quiet card, with an optional label above (Settings groups). No dividers: the
/// rows' own spacing separates them.
class KitGroup extends StatelessWidget {
  const KitGroup({super.key, this.label, required this.children, this.padding = const EdgeInsets.all(4)});

  final String? label;
  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label case final l? when l.isNotEmpty) KitLabel(l, padding: const EdgeInsets.fromLTRB(8, 0, 8, 8)),
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.surfaceRaised.withValues(alpha: theme.isDark ? 0.55 : 0.6),
              borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
              border: Border.all(color: theme.border),
            ),
            child: Padding(
              padding: padding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
