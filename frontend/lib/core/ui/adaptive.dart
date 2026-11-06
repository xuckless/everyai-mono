import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../motion/motion.dart';
import '../platform/platform_kind.dart';
import '../theme/every_theme.dart';
import 'anchored_popover.dart';
import 'every_icons.dart';
import 'kit.dart';

export 'kit.dart';
export 'list_editor.dart';

/// The building blocks screens compose. Since the 2026-11 overhaul they all
/// render the EveryAI kit (`kit.dart`), the same on every platform; the names
/// stay so screens didn't have to change at once. Material is only used as the
/// text-editing engine under [AdaptiveTextField].

DesignLanguage designOf(BuildContext context) => EveryTheme.of(context).design;

class AdaptiveIcon extends StatelessWidget {
  const AdaptiveIcon(this.icon, {super.key, this.size, this.color});

  final EveryIcon icon;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Icon(icon.data, size: size, color: color);
}

class AdaptiveIconButton extends StatelessWidget {
  const AdaptiveIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
    this.size,
  });

  final EveryIcon icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final double? size;

  @override
  Widget build(BuildContext context) =>
      KitIconButton(icon: icon, tooltip: tooltip, onPressed: onPressed, color: color, size: size, touch: Host.isMobile);
}

enum ButtonEmphasis { primary, secondary, plain, destructive }

class AdaptiveButton extends StatelessWidget {
  const AdaptiveButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.emphasis = ButtonEmphasis.primary,
    this.icon,
    this.expand = false,
    this.busy = false,
    bool? large,
  }) : large = large ?? expand;

  final String label;
  final VoidCallback? onPressed;
  final ButtonEmphasis emphasis;
  final Widget? icon;
  final bool expand;

  /// 44pt, for forms and full-width actions. Buttons inside content are 32pt.
  final bool large;

  /// Shows a spinner in place of the label and disables the button.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final style = switch (emphasis) {
      ButtonEmphasis.primary => KitButtonStyle.primary,
      ButtonEmphasis.secondary => KitButtonStyle.soft,
      ButtonEmphasis.plain => KitButtonStyle.ghost,
      ButtonEmphasis.destructive => KitButtonStyle.danger,
    };
    return KitButton(
      label: label,
      onPressed: onPressed,
      style: style,
      large: large,
      expand: expand,
      busy: busy,
      leading: icon,
    );
  }
}

class AdaptiveTextField extends StatelessWidget {
  const AdaptiveTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.placeholder,
    this.obscureText = false,
    this.autofillHints,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.minLines,
    this.maxLines = 1,
    this.prefix,
    this.autofocus = false,
    this.borderless = false,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? placeholder;
  final bool obscureText;
  final Iterable<String>? autofillHints;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final int? minLines;
  final int? maxLines;
  final Widget? prefix;
  final bool autofocus;

  /// For fields embedded in a custom container (the composer).
  final bool borderless;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final style = theme.type.body.copyWith(height: 1.45).tint(theme.text);
    final hint = style.tint(theme.textSubtle);
    final radius = BorderRadius.circular(10);
    // Material's field is only the editing engine here (platform selection
    // handles and menus); every visible part comes from the kit.
    return onMaterial(
      context,
      m.TextField(
        controller: controller,
        focusNode: focusNode,
        obscureText: obscureText,
        autofillHints: autofillHints,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        onSubmitted: onSubmitted,
        onChanged: onChanged,
        minLines: minLines,
        maxLines: maxLines,
        autofocus: autofocus,
        style: style,
        cursorColor: theme.accent,
        cursorWidth: 1.6,
        decoration: borderless
            ? m.InputDecoration.collapsed(hintText: placeholder, hintStyle: hint)
            : m.InputDecoration(
                hintText: placeholder,
                hintStyle: hint,
                prefixIcon: prefix == null
                    ? null
                    : Padding(padding: const EdgeInsets.only(left: 10, right: 6), child: prefix),
                prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                filled: true,
                fillColor: theme.well,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                hoverColor: const Color(0x00000000),
                border: m.OutlineInputBorder(
                  borderRadius: radius,
                  borderSide: BorderSide(color: theme.border),
                ),
                enabledBorder: m.OutlineInputBorder(
                  borderRadius: radius,
                  borderSide: BorderSide(color: theme.border),
                ),
                focusedBorder: m.OutlineInputBorder(
                  borderRadius: radius,
                  borderSide: BorderSide(color: theme.accent.withValues(alpha: 0.7)),
                ),
              ),
      ),
    );
  }
}

class AdaptiveSwitch extends StatelessWidget {
  const AdaptiveSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => KitSwitch(value: value, onChanged: onChanged);
}

class AdaptiveProgress extends StatelessWidget {
  const AdaptiveProgress({super.key, this.value});

  final double? value;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (value == null) return const SizedBox.square(dimension: 18, child: KitSpinner());
    return SizedBox(
      width: 120,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: Container(
          height: 4,
          color: theme.borderStrong,
          alignment: AlignmentDirectional.centerStart,
          child: AnimatedFractionallySizedBox(
            duration: const Duration(milliseconds: 400),
            curve: Motion.easeInOut,
            widthFactor: value!.clamp(0, 1),
            child: ColoredBox(color: theme.accent, child: const SizedBox.expand()),
          ),
        ),
      ),
    );
  }
}

/// A row in a list: conversations, settings, models.
class AdaptiveListTile extends StatelessWidget {
  const AdaptiveListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.dense = false,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final touch = Host.isMobile;
    // A wide trailing widget (a value, a picker) never takes the title's room: at most 55% of the row.
    return LayoutBuilder(
      builder: (context, box) => MenuRow(
        onTap: onTap,
        selected: selected,
        touch: touch && !dense,
        leading: leading,
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: dense ? 6 : (touch ? 10 : 8)),
        trailing: trailing == null
            ? null
            : ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.maxWidth.isFinite ? box.maxWidth * 0.55 : double.infinity),
                child: DefaultTextStyle.merge(style: theme.type.callout.tint(theme.textSubtle), child: trailing!),
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            DefaultTextStyle.merge(maxLines: 1, overflow: TextOverflow.ellipsis, child: title),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: DefaultTextStyle.merge(
                  style: theme.type.caption.tint(theme.textSubtle),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  child: subtitle!,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Section header for grouped lists ("Today", "Appearance").
class AdaptiveSectionHeader extends StatelessWidget {
  const AdaptiveSectionHeader(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => KitLabel(label, padding: const EdgeInsets.fromLTRB(12, 16, 12, 6));
}

/// A menu item for [AdaptiveMenuButton].
@immutable
class MenuAction {
  const MenuAction({
    required this.label,
    required this.onSelected,
    this.icon,
    this.checked = false,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onSelected;
  final EveryIcon? icon;
  final bool checked;
  final bool destructive;
}

/// A button that opens a menu. Every menu in the app is the same anchored
/// glass popover with [PopoverRow]s (the model picker, the composer's menus,
/// "…" menus, value pickers), on every platform, so they all look alike.
class AdaptiveMenuButton extends StatelessWidget {
  const AdaptiveMenuButton({super.key, required this.actions, required this.child, this.tooltip, this.width});

  final List<MenuAction> actions;
  final Widget child;
  final String? tooltip;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final popover = AnchoredPopover(
      width: width,
      builder: (context, close) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, a) in actions.indexed)
              PopoverRow(
                title: a.label,
                destructive: a.destructive,
                selected: a.checked,
                leading: a.icon == null
                    ? null
                    : AdaptiveIcon(a.icon!, size: 16, color: a.destructive ? theme.danger : theme.textMuted),
                trailing: a.checked ? Icon(EveryIcon.check.data, size: 14, color: theme.accentText) : null,
                onTap: () {
                  close();
                  a.onSelected();
                },
              ).rowIn(i),
          ],
        ),
      ),
      child: child,
    );
    return tooltip == null ? popover : Semantics(label: tooltip, button: true, child: popover);
  }
}

/// The trigger for a value picker: the current value in accent text with an
/// up/down chevron, like a native pop-up button. Pair it with
/// [AdaptiveMenuButton] or [AnchoredPopover].
class MenuTrigger extends StatelessWidget {
  const MenuTrigger(this.label, {super.key, this.leading, this.muted = false});

  final String label;
  final Widget? leading;

  /// Secondary text color instead of the accent (triggers inside dense chrome).
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final color = muted ? theme.textMuted : theme.text;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 6)],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.type.callout.medium.tint(color),
            ),
          ),
          const SizedBox(width: 4),
          Icon(EveryIcon.chevronDown.data, size: 13, color: theme.textSubtle),
        ],
      ),
    );
  }
}

/// Confirmation dialog. Resolves to true when the user confirms.
/// `detail` is shown in full below the message, in a scrolling box (for text
/// the user is asked to approve, which must never be cut short).
Future<bool> showAdaptiveConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
  String? detail,
}) async {
  final result = await showKitDialog<bool>(
    context,
    builder: (ctx) => KitDialog(
      title: title,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message.isNotEmpty) Text(message),
          if (detail != null) ...[const SizedBox(height: 10), ConfirmDetail(detail)],
        ],
      ),
      actions: [
        KitButton(
          label: 'Cancel',
          style: KitButtonStyle.ghost,
          shortcut: 'esc',
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
        KitButton(
          label: confirmLabel,
          style: destructive ? KitButtonStyle.danger : KitButtonStyle.primary,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// The full text a confirmation asks about, in a scrolling box.
class ConfirmDetail extends StatelessWidget {
  const ConfirmDetail(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.codeBackground,
          border: Border.all(color: theme.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(10),
          child: Text(text, textAlign: TextAlign.start, style: theme.type.callout.tint(theme.text)),
        ),
      ),
    );
  }
}

/// Single-field text prompt (rename and similar; [obscureText] for secrets).
/// Returns null when cancelled.
Future<String?> showAdaptivePrompt(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String initialValue = '',
  bool obscureText = false,
  String? placeholder,
}) async {
  // The field owns its controller, so it outlives the dialog's closing animation.
  var text = initialValue;
  return showKitDialog<String>(
    context,
    builder: (ctx) => KitDialog(
      title: title,
      body: _PromptField(
        initialValue: initialValue,
        obscureText: obscureText,
        placeholder: placeholder,
        onChanged: (v) => text = v,
        onSubmitted: (value) => Navigator.of(ctx).pop(value),
      ),
      actions: [
        KitButton(label: 'Cancel', style: KitButtonStyle.ghost, onPressed: () => Navigator.of(ctx).pop()),
        KitButton(label: confirmLabel, onPressed: () => Navigator.of(ctx).pop(text)),
      ],
    ),
  );
}

/// Opens [builder] as a centred modal: scrim fades, the panel grows from 0.95
/// with an ease-out (200ms) and leaves 20% faster.
Future<T?> showKitDialog<T>(BuildContext context, {required WidgetBuilder builder, bool dismissible = true}) {
  final theme = EveryTheme.of(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: 'Dismiss',
    barrierColor: theme.scrim,
    transitionDuration: Motion.popIn,
    pageBuilder: (ctx, _, _) => EveryThemeScope(theme: theme, child: builder(ctx)),
    transitionBuilder: (ctx, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: Motion.easeOut, reverseCurve: Motion.easeExit);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween(begin: Motion.popoverStartScale, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// The kit's modal panel: a title, a body and right-aligned actions.
class KitDialog extends StatelessWidget {
  const KitDialog({super.key, required this.title, required this.body, this.actions = const [], this.width = 420});

  final String title;
  final Widget body;
  final List<Widget> actions;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 18, 16, 14),
            decoration: BoxDecoration(
              color: theme.overlay,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.borderStrong),
              boxShadow: theme.shadowPop,
            ),
            child: DefaultTextStyle(
              style: theme.type.callout.tint(theme.textMuted),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(title, style: theme.type.headline.tint(theme.text)),
                  const SizedBox(height: 8),
                  Flexible(child: SingleChildScrollView(child: body)),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Wrap(alignment: WrapAlignment.end, spacing: 6, runSpacing: 6, children: actions),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PromptField extends StatefulWidget {
  const _PromptField({
    required this.initialValue,
    required this.obscureText,
    required this.placeholder,
    required this.onChanged,
    required this.onSubmitted,
  });

  final String initialValue;
  final bool obscureText;
  final String? placeholder;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  State<_PromptField> createState() => _PromptFieldState();
}

class _PromptFieldState extends State<_PromptField> {
  late final _controller = TextEditingController(text: widget.initialValue)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initialValue.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AdaptiveTextField(
    controller: _controller,
    autofocus: true,
    obscureText: widget.obscureText,
    placeholder: widget.placeholder,
    textInputAction: TextInputAction.done,
    onChanged: widget.onChanged,
    onSubmitted: widget.onSubmitted,
  );
}

/// Transient message: a pill near the bottom that settles in, stays 1.7s and
/// fades out. Its lifetime runs on a ticker, so it goes with the tree.
void showAdaptiveToast(BuildContext context, String message) {
  final theme = EveryTheme.of(context);
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  final bottom = 32 + MediaQuery.paddingOf(context).bottom;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => EveryThemeScope(
      theme: theme,
      child: _Toast(message: message, bottom: bottom, onDone: () => entry.remove()),
    ),
  );
  overlay.insert(entry);
}

class _Toast extends StatefulWidget {
  const _Toast({required this.message, required this.bottom, required this.onDone});
  final String message;
  final double bottom;
  final VoidCallback onDone;

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  static const _stay = Duration(milliseconds: 1700);
  late final _c = AnimationController(vsync: this, duration: _stay + Motion.popOut)
    ..forward().whenCompleteOrCancel(() {
      if (mounted) widget.onDone();
    });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final total = (_stay + Motion.popOut).inMicroseconds;
    final fade = CurvedAnimation(
      parent: _c,
      curve: Interval(_stay.inMicroseconds / total, 1, curve: Motion.easeExit),
    );
    return Positioned(
      left: 0,
      right: 0,
      bottom: widget.bottom,
      child: IgnorePointer(
        child: Center(
          child: FadeTransition(
            opacity: ReverseAnimation(fade),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: theme.overlay,
                borderRadius: BorderRadius.circular(99),
                border: Border.all(color: theme.borderStrong),
                boxShadow: theme.shadowPop,
              ),
              child: Text(widget.message, style: theme.type.callout.tint(theme.text)),
            ).settle(),
          ),
        ),
      ),
    );
  }
}

/// The brand kit's glass levels.
enum GlassLevel {
  /// Composer, chips, toolbars.
  thin(blur: 20, saturate: 1.4),

  /// Sidebar and rail.
  regular(blur: 30, saturate: 1.6),

  /// Popovers, menus, sheets.
  thick(blur: 44, saturate: 1.8);

  const GlassLevel({required this.blur, required this.saturate});
  final double blur;
  final double saturate;

  /// Tint over the blurred backdrop (the kit specifies dark; light mirrors it).
  Color tint(EveryTheme theme) => switch (this) {
    thin => theme.isDark ? const Color(0x0FFFFFFF) : const Color(0xB3FFFFFF),
    regular => theme.isDark ? EveryPalette.ink900.withValues(alpha: 0.55) : const Color(0xB3FAFAFE),
    thick => theme.isDark ? EveryPalette.ink850.withValues(alpha: 0.78) : const Color(0xE6FFFFFF),
  };

  Color border(EveryTheme theme) => theme.isDark
      ? switch (this) {
          thin => const Color(0x29FFFFFF),
          regular => const Color(0x1AFFFFFF),
          thick => const Color(0x1FFFFFFF),
        }
      : theme.border;

  /// The 1px specular line along the top edge.
  Color highlight(EveryTheme theme) => theme.isDark
      ? switch (this) {
          thin => const Color(0x47FFFFFF),
          regular => const Color(0x24FFFFFF),
          thick => const Color(0x2EFFFFFF),
        }
      : const Color(0xCCFFFFFF);
}

/// Translucent material behind floating chrome (composer, popovers, toasts),
/// following the brand kit's glass recipes: backdrop blur and saturation, a
/// tint, a hairline border and a top highlight. Works on every renderer.
class GlassSurface extends StatelessWidget {
  const GlassSurface({super.key, required this.child, this.radius, this.padding, this.level = GlassLevel.thin});

  final Widget child;
  final double? radius;
  final EdgeInsetsGeometry? padding;
  final GlassLevel level;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final r = BorderRadius.circular(radius ?? theme.radius);
    // The kit uses solid surfaces: overlays for popovers, raised for chrome.
    final color = level == GlassLevel.thick ? theme.overlay : theme.surfaceRaised;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: r,
        border: Border.all(color: level == GlassLevel.thick ? theme.borderStrong : theme.border),
        boxShadow: level == GlassLevel.thick ? theme.shadowPop : null,
      ),
      child: ClipRRect(
        borderRadius: r,
        child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
      ),
    );
  }
}

/// [child] (a Material widget: ListTile, TextField, InkWell) on a transparent Material when nothing above gives it
/// one, so it works in any parent instead of throwing "No Material widget found".
Widget onMaterial(BuildContext context, Widget child) =>
    m.Material.maybeOf(context) != null ? child : m.Material(type: m.MaterialType.transparency, child: child);

/// A widget that sits in a [KitGroupedList] card like a row when [groupsInCard] says so (a wrapper such as a
/// Settings anchor around a list tile).
abstract interface class KitRowLike {
  bool get groupsInCard;
}

/// Whether [w] is a settings-style row that belongs on a card.
bool kitIsRow(Widget w) => w is AdaptiveListTile || w is MenuRow || (w is KitRowLike && (w as KitRowLike).groupsInCard);

/// A scrolling settings page from a flat list of children: runs of rows (list tiles, or wrappers of them) go
/// together on one [KitGroup] card, an [AdaptiveSectionHeader] becomes the label of the card after it, and anything
/// else (an editor, a note, a chart) stands on its own between the cards.
class KitGroupedList extends StatelessWidget {
  const KitGroupedList({super.key, required this.children, this.padding = const EdgeInsets.fromLTRB(20, 4, 20, 28)});

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  /// [children] folded into cards.
  static List<Widget> fold(List<Widget> children) {
    final out = <Widget>[];
    String? label;
    var run = <Widget>[];
    void flush() {
      if (run.isNotEmpty) {
        out.add(KitGroup(label: label, children: run));
      } else if (label case final l?) {
        out.add(KitLabel(l, padding: const EdgeInsets.fromLTRB(8, 0, 8, 8)));
      }
      run = [];
      label = null;
    }

    for (final c in children) {
      if (c is AdaptiveSectionHeader) {
        flush();
        label = c.label;
      } else if (kitIsRow(c)) {
        run.add(c);
      } else if (c is SizedBox && c.child == null) {
        // Spacers between rows don't break a card.
        if (run.isEmpty) out.add(c);
      } else {
        if (run.isNotEmpty) {
          flush();
        } else if (label case final l?) {
          out.add(KitLabel(l, padding: const EdgeInsets.fromLTRB(8, 0, 8, 8)));
          label = null;
        }
        out.add(Padding(padding: const EdgeInsets.only(bottom: 14), child: c));
      }
    }
    flush();
    return out;
  }

  @override
  Widget build(BuildContext context) => ListView(padding: padding, children: fold(children));
}
