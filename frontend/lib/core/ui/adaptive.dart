import 'dart:ui' show ImageFilter;

import 'package:cupertino_ui/cupertino_ui.dart' as c;
import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart' as mac;
import 'package:material_ui/material_ui.dart' as m;

import '../platform/platform_kind.dart';
import '../theme/every_theme.dart';
import 'anchored_popover.dart';
import 'every_icons.dart';

/// Design-language-aware building blocks. Screens compose these instead of
/// importing a design system directly, so one screen definition renders
/// natively as Cupertino, macOS, Material 3, Fluent or Adwaita.
///
/// Each design system lives behind an import prefix:
/// `c` (cupertino_ui), `mac` (macos_ui), `m` (material_ui), `f` (fluent_ui).

DesignLanguage designOf(BuildContext context) => EveryTheme.of(context).design;

class AdaptiveIcon extends StatelessWidget {
  const AdaptiveIcon(this.icon, {super.key, this.size, this.color});

  final EveryIcon icon;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Icon(icon.of(designOf(context)), size: size, color: color);
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
  Widget build(BuildContext context) {
    final design = designOf(context);
    final glyph = Icon(icon.of(design), size: size, color: color);
    return switch (design) {
      DesignLanguage.cupertino => Semantics(
        label: tooltip,
        button: true,
        child: c.CupertinoButton(
          padding: const EdgeInsets.all(8),
          minimumSize: const Size.square(40),
          onPressed: onPressed,
          child: glyph,
        ),
      ),
      DesignLanguage.macos => mac.MacosTooltip(
        message: tooltip,
        child: mac.MacosIconButton(
          icon: Icon(
            icon.of(design),
            size: size ?? 18,
            color: color ?? mac.MacosTheme.of(context).typography.body.color,
          ),
          semanticLabel: tooltip,
          boxConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          padding: const EdgeInsets.all(5),
          onPressed: onPressed,
        ),
      ),
      DesignLanguage.fluent => f.Tooltip(
        message: tooltip,
        child: f.IconButton(
          icon: Icon(icon.of(design), size: size ?? 16, color: color),
          onPressed: onPressed,
        ),
      ),
      DesignLanguage.material ||
      DesignLanguage.adwaita => m.IconButton(tooltip: tooltip, icon: glyph, onPressed: onPressed),
    };
  }
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
  });

  final String label;
  final VoidCallback? onPressed;
  final ButtonEmphasis emphasis;
  final Widget? icon;
  final bool expand;

  /// Shows a spinner in place of the label and disables the button.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final onPressed = busy ? null : this.onPressed;
    final content = busy
        ? const SizedBox.square(dimension: 18, child: AdaptiveProgress())
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[icon!, const SizedBox(width: 8)],
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
            ],
          );
    final destructive = emphasis == ButtonEmphasis.destructive;

    final Widget button = switch (theme.design) {
      DesignLanguage.cupertino => switch (emphasis) {
        ButtonEmphasis.primary => c.CupertinoButton.filled(onPressed: onPressed, child: content),
        ButtonEmphasis.secondary => c.CupertinoButton.tinted(onPressed: onPressed, child: content),
        _ => c.CupertinoButton(
          onPressed: onPressed,
          child: DefaultTextStyle.merge(
            style: TextStyle(color: destructive ? theme.danger : null),
            child: content,
          ),
        ),
      },
      DesignLanguage.macos => mac.PushButton(
        controlSize: mac.ControlSize.large,
        secondary: emphasis != ButtonEmphasis.primary,
        color: destructive ? theme.danger : null,
        onPressed: onPressed,
        child: content,
      ),
      DesignLanguage.fluent => switch (emphasis) {
        ButtonEmphasis.primary => f.FilledButton(onPressed: onPressed, child: content),
        ButtonEmphasis.plain => f.HyperlinkButton(onPressed: onPressed, child: content),
        _ => f.Button(
          onPressed: onPressed,
          child: DefaultTextStyle.merge(
            style: TextStyle(color: destructive ? theme.danger : null),
            child: content,
          ),
        ),
      },
      DesignLanguage.material || DesignLanguage.adwaita => switch (emphasis) {
        ButtonEmphasis.primary => m.FilledButton(onPressed: onPressed, child: content),
        ButtonEmphasis.secondary => m.FilledButton.tonal(onPressed: onPressed, child: content),
        ButtonEmphasis.plain => m.TextButton(onPressed: onPressed, child: content),
        ButtonEmphasis.destructive => m.TextButton(
          style: m.TextButton.styleFrom(foregroundColor: theme.danger),
          onPressed: onPressed,
          child: content,
        ),
      },
    };
    return expand ? SizedBox(width: double.infinity, child: button) : button;
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
    return switch (theme.design) {
      DesignLanguage.cupertino => c.CupertinoTextField(
        controller: controller,
        focusNode: focusNode,
        placeholder: placeholder,
        obscureText: obscureText,
        autofillHints: autofillHints,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        onSubmitted: onSubmitted,
        onChanged: onChanged,
        minLines: minLines,
        maxLines: maxLines,
        autofocus: autofocus,
        prefix: prefix == null ? null : Padding(padding: const EdgeInsets.only(left: 8), child: prefix),
        padding: borderless ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        placeholderStyle: TextStyle(color: theme.textMuted),
        decoration: borderless
            ? null
            : BoxDecoration(color: theme.surfaceRaised, borderRadius: BorderRadius.circular(theme.radius)),
        style: TextStyle(color: theme.text),
      ),
      DesignLanguage.macos => mac.MacosTextField(
        controller: controller,
        focusNode: focusNode,
        placeholder: placeholder,
        obscureText: obscureText,
        autofillHints: autofillHints,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        onSubmitted: onSubmitted,
        onChanged: onChanged,
        minLines: minLines,
        maxLines: maxLines,
        autofocus: autofocus,
        prefix: prefix,
        padding: borderless ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        style: TextStyle(color: theme.text, fontSize: borderless ? 14 : 13),
        placeholderStyle: TextStyle(color: theme.textMuted.withValues(alpha: 0.8)),
        // macos_ui paints a 3px focus ring onto any non-null focusedDecoration.
        decoration: borderless ? null : mac.kDefaultRoundedBorderDecoration,
        focusedDecoration: borderless ? null : mac.kDefaultFocusedBorderDecoration,
      ),
      DesignLanguage.fluent => f.TextBox(
        controller: controller,
        focusNode: focusNode,
        placeholder: placeholder,
        obscureText: obscureText,
        autofillHints: autofillHints,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        onSubmitted: onSubmitted,
        onChanged: onChanged,
        minLines: minLines,
        maxLines: maxLines,
        autofocus: autofocus,
        prefix: prefix == null ? null : Padding(padding: const EdgeInsets.only(left: 8), child: prefix),
        decoration: borderless ? const f.WidgetStatePropertyAll(BoxDecoration()) : null,
        highlightColor: borderless ? const Color(0x00000000) : null,
        unfocusedColor: borderless ? const Color(0x00000000) : null,
      ),
      DesignLanguage.material || DesignLanguage.adwaita => m.TextField(
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
        decoration: borderless
            ? m.InputDecoration.collapsed(hintText: placeholder)
            : m.InputDecoration(
                hintText: placeholder,
                prefixIcon: prefix,
                filled: true,
                isDense: true,
                border: m.OutlineInputBorder(
                  borderRadius: BorderRadius.circular(theme.radius),
                  borderSide: theme.design == DesignLanguage.adwaita
                      ? BorderSide(color: theme.border)
                      : BorderSide.none,
                ),
              ),
      ),
    };
  }
}

class AdaptiveSwitch extends StatelessWidget {
  const AdaptiveSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => switch (designOf(context)) {
    DesignLanguage.cupertino => c.CupertinoSwitch(value: value, onChanged: onChanged),
    DesignLanguage.macos => mac.MacosSwitch(value: value, onChanged: onChanged),
    DesignLanguage.fluent => f.ToggleSwitch(checked: value, onChanged: onChanged),
    DesignLanguage.material || DesignLanguage.adwaita => m.Switch(value: value, onChanged: onChanged),
  };
}

class AdaptiveProgress extends StatelessWidget {
  const AdaptiveProgress({super.key, this.value});

  final double? value;

  @override
  Widget build(BuildContext context) => switch (designOf(context)) {
    DesignLanguage.cupertino => const c.CupertinoActivityIndicator(),
    DesignLanguage.macos => mac.ProgressCircle(value: value),
    DesignLanguage.fluent => f.ProgressRing(value: value == null ? null : value! * 100, strokeWidth: 2.5),
    DesignLanguage.material || DesignLanguage.adwaita => m.CircularProgressIndicator(value: value, strokeWidth: 2.5),
  };
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
    switch (theme.design) {
      case DesignLanguage.fluent:
        return f.ListTile.selectable(
          leading: leading,
          title: title,
          subtitle: subtitle,
          trailing: trailing,
          selected: selected,
          onPressed: onTap,
        );
      case DesignLanguage.material || DesignLanguage.adwaita:
        return m.ListTile(
          leading: leading,
          title: title,
          subtitle: subtitle,
          trailing: trailing,
          selected: selected,
          dense: dense,
          onTap: onTap,
          shape: m.RoundedRectangleBorder(borderRadius: BorderRadius.circular(theme.radius)),
        );
      case DesignLanguage.cupertino || DesignLanguage.macos:
        // Apple lists: a rounded highlight for the selection, and secondary text in the label color.
        final highlight = selected ? theme.accent.withValues(alpha: theme.isDark ? 0.22 : 0.14) : null;
        return _PressableRow(
          onTap: onTap,
          highlight: highlight,
          radius: theme.radius,
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: dense ? 6 : 10),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 10)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DefaultTextStyle.merge(
                      style: TextStyle(color: theme.text, fontSize: theme.design == DesignLanguage.macos ? 13 : 16),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      child: title,
                    ),
                    if (subtitle != null)
                      DefaultTextStyle.merge(
                        style: TextStyle(
                          color: theme.textMuted,
                          fontSize: theme.design == DesignLanguage.macos ? 11 : 13,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        child: subtitle!,
                      ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
        );
    }
  }
}

class _PressableRow extends StatefulWidget {
  const _PressableRow({
    required this.child,
    required this.onTap,
    required this.highlight,
    required this.radius,
    required this.padding,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Color? highlight;
  final double radius;
  final EdgeInsets padding;

  @override
  State<_PressableRow> createState() => _PressableRowState();
}

class _PressableRowState extends State<_PressableRow> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final overlay = _down
        ? theme.text.withValues(alpha: 0.10)
        : _hover
        ? theme.text.withValues(alpha: 0.05)
        : null;
    return MouseRegion(
      cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap,
        child: Semantics(
          button: widget.onTap != null,
          selected: widget.highlight != null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: widget.padding,
            decoration: BoxDecoration(
              color: Color.alphaBlend(overlay ?? const Color(0x00000000), widget.highlight ?? const Color(0x00000000)),
              borderRadius: BorderRadius.circular(widget.radius),
            ),
            child: widget.child,
          ),
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
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final upper = theme.design == DesignLanguage.cupertino;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
      child: Text(
        upper ? label.toUpperCase() : label,
        style: TextStyle(
          color: theme.textMuted,
          fontSize: switch (theme.design) {
            DesignLanguage.macos => 11,
            DesignLanguage.cupertino => 13,
            _ => 12,
          },
          fontWeight: FontWeight.w600,
          letterSpacing: upper ? 0.4 : 0.1,
        ),
      ),
    );
  }
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

/// A button that opens a native menu: pull-down (macOS), context menu (iOS),
/// flyout (Windows) or Material menu.
class AdaptiveMenuButton extends StatelessWidget {
  const AdaptiveMenuButton({super.key, required this.actions, required this.child, this.tooltip});

  final List<MenuAction> actions;
  final Widget child;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    Widget check(MenuAction a) =>
        SizedBox(width: 20, child: a.checked ? Icon(EveryIcon.check.of(theme.design), size: 14) : null);
    switch (theme.design) {
      case DesignLanguage.fluent:
        return f.DropDownButton(
          title: child,
          items: [
            for (final a in actions)
              f.MenuFlyoutItem(
                leading: check(a),
                text: Text(a.label, style: TextStyle(color: a.destructive ? theme.danger : null)),
                onPressed: a.onSelected,
              ),
          ],
        );
      case DesignLanguage.macos:
        return AnchoredPopover(
          builder: (context, close) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final a in actions)
                  PopoverRow(
                    title: a.label,
                    destructive: a.destructive,
                    trailing: a.checked ? Icon(EveryIcon.check.of(theme.design), size: 14, color: theme.accent) : null,
                    onTap: () {
                      close();
                      a.onSelected();
                    },
                  ),
              ],
            ),
          ),
          child: child,
        );
      case DesignLanguage.cupertino:
        return _CupertinoMenuButton(actions: actions, child: child);
      case DesignLanguage.material || DesignLanguage.adwaita:
        return m.MenuAnchor(
          menuChildren: [
            for (final a in actions)
              m.MenuItemButton(
                leadingIcon: a.icon == null ? check(a) : Icon(a.icon!.of(theme.design), size: 18),
                trailingIcon: a.icon != null && a.checked ? Icon(EveryIcon.check.of(theme.design), size: 18) : null,
                style: a.destructive ? m.MenuItemButton.styleFrom(foregroundColor: theme.danger) : null,
                onPressed: a.onSelected,
                child: Text(a.label),
              ),
          ],
          builder: (context, controller, _) => m.InkWell(
            borderRadius: BorderRadius.circular(theme.radius),
            onTap: () => controller.isOpen ? controller.close() : controller.open(),
            child: child,
          ),
        );
    }
  }
}

class _CupertinoMenuButton extends StatelessWidget {
  const _CupertinoMenuButton({required this.actions, required this.child});

  final List<MenuAction> actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => c.showCupertinoModalPopup<void>(
        context: context,
        builder: (sheetContext) => c.CupertinoActionSheet(
          actions: [
            for (final a in actions)
              c.CupertinoActionSheetAction(
                isDestructiveAction: a.destructive,
                isDefaultAction: a.checked,
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  a.onSelected();
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(a.label),
                    if (a.checked) ...[const SizedBox(width: 6), Icon(EveryIcon.check.of(theme.design), size: 16)],
                  ],
                ),
              ),
          ],
          cancelButton: c.CupertinoActionSheetAction(
            onPressed: () => Navigator.of(sheetContext).pop(),
            child: const Text('Cancel'),
          ),
        ),
      ),
      child: child,
    );
  }
}

/// Native confirmation dialog. Resolves to true when the user confirms.
Future<bool> showAdaptiveConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final theme = EveryTheme.of(context);
  final Future<bool?> result = switch (theme.design) {
    DesignLanguage.cupertino => c.showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => c.CupertinoAlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          c.CupertinoDialogAction(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          c.CupertinoDialogAction(
            isDestructiveAction: destructive,
            isDefaultAction: !destructive,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
    DesignLanguage.macos => mac.showMacosAlertDialog<bool>(
      context: context,
      builder: (ctx) => mac.MacosAlertDialog(
        appIcon: AdaptiveIcon(destructive ? EveryIcon.delete : EveryIcon.spark, size: 40, color: theme.accent),
        title: Text(title),
        message: Text(message, textAlign: TextAlign.center),
        primaryButton: mac.PushButton(
          controlSize: mac.ControlSize.large,
          color: destructive ? theme.danger : null,
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel),
        ),
        secondaryButton: mac.PushButton(
          controlSize: mac.ControlSize.large,
          secondary: true,
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
      ),
    ),
    DesignLanguage.fluent => f.showDialog<bool>(
      context: context,
      builder: (ctx) => f.ContentDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          f.FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(confirmLabel)),
          f.Button(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
        ],
      ),
    ),
    DesignLanguage.material || DesignLanguage.adwaita => m.showDialog<bool>(
      context: context,
      builder: (ctx) => m.AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          m.TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          m.FilledButton(
            style: destructive ? m.FilledButton.styleFrom(backgroundColor: theme.danger) : null,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
  };
  return await result ?? false;
}

/// Single-field text prompt (rename and similar). Returns null when cancelled.
Future<String?> showAdaptivePrompt(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String initialValue = '',
}) async {
  final theme = EveryTheme.of(context);
  final controller = TextEditingController(text: initialValue)
    ..selection = TextSelection(baseOffset: 0, extentOffset: initialValue.length);
  Widget field(BuildContext ctx) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: AdaptiveTextField(
      controller: controller,
      autofocus: true,
      textInputAction: TextInputAction.done,
      onSubmitted: (value) => Navigator.of(ctx).pop(value),
    ),
  );
  void cancel(BuildContext ctx) => Navigator.of(ctx).pop();
  void confirm(BuildContext ctx) => Navigator.of(ctx).pop(controller.text);

  final Future<String?> result = switch (theme.design) {
    DesignLanguage.cupertino => c.showCupertinoDialog<String>(
      context: context,
      builder: (ctx) => c.CupertinoAlertDialog(
        title: Text(title),
        content: field(ctx),
        actions: [
          c.CupertinoDialogAction(onPressed: () => cancel(ctx), child: const Text('Cancel')),
          c.CupertinoDialogAction(isDefaultAction: true, onPressed: () => confirm(ctx), child: Text(confirmLabel)),
        ],
      ),
    ),
    DesignLanguage.macos => mac.showMacosAlertDialog<String>(
      context: context,
      builder: (ctx) => mac.MacosAlertDialog(
        appIcon: AdaptiveIcon(EveryIcon.edit, size: 40, color: theme.accent),
        title: Text(title),
        message: field(ctx),
        primaryButton: mac.PushButton(
          controlSize: mac.ControlSize.large,
          onPressed: () => confirm(ctx),
          child: Text(confirmLabel),
        ),
        secondaryButton: mac.PushButton(
          controlSize: mac.ControlSize.large,
          secondary: true,
          onPressed: () => cancel(ctx),
          child: const Text('Cancel'),
        ),
      ),
    ),
    DesignLanguage.fluent => f.showDialog<String>(
      context: context,
      builder: (ctx) => f.ContentDialog(
        title: Text(title),
        content: field(ctx),
        actions: [
          f.FilledButton(onPressed: () => confirm(ctx), child: Text(confirmLabel)),
          f.Button(onPressed: () => cancel(ctx), child: const Text('Cancel')),
        ],
      ),
    ),
    DesignLanguage.material || DesignLanguage.adwaita => m.showDialog<String>(
      context: context,
      builder: (ctx) => m.AlertDialog(
        title: Text(title),
        content: field(ctx),
        actions: [
          m.TextButton(onPressed: () => cancel(ctx), child: const Text('Cancel')),
          m.FilledButton(onPressed: () => confirm(ctx), child: Text(confirmLabel)),
        ],
      ),
    ),
  };
  try {
    return await result;
  } finally {
    controller.dispose();
  }
}

/// Transient message: toast-style on desktop, snack bar on Material.
void showAdaptiveToast(BuildContext context, String message) {
  final theme = EveryTheme.of(context);
  if (theme.design == DesignLanguage.material || theme.design == DesignLanguage.adwaita) {
    m.ScaffoldMessenger.maybeOf(context)?.showSnackBar(m.SnackBar(content: Text(message)));
    return;
  }
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => Positioned(
      left: 0,
      right: 0,
      bottom: 32 + MediaQuery.paddingOf(context).bottom,
      child: IgnorePointer(
        child: Center(
          child: GlassSurface(
            radius: 999,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(message, style: TextStyle(color: theme.text, fontSize: 14)),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Future<void>.delayed(const Duration(seconds: 2), entry.remove);
}

/// Translucent material behind floating chrome (the composer, toasts, iOS bars).
///
/// A frosted-glass approximation of Apple's Liquid Glass: backdrop blur, a
/// tinted fill and a specular rim. It works on every renderer, web included.
/// Shader-based refraction (liquid_glass_renderer) needs Impeller + Flutter GPU
/// and is a later upgrade.
class GlassSurface extends StatelessWidget {
  const GlassSurface({super.key, required this.child, this.radius, this.padding, this.blur = 24});

  final Widget child;
  final double? radius;
  final EdgeInsetsGeometry? padding;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final r = BorderRadius.circular(radius ?? theme.radius);
    final glass = theme.design == DesignLanguage.cupertino || theme.design == DesignLanguage.macos;
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: glass ? blur : 0, sigmaY: glass ? blur : 0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: r,
            color: glass ? theme.surface.withValues(alpha: theme.isDark ? 0.55 : 0.62) : theme.surfaceRaised,
            border: Border.all(
              color: glass ? const Color(0xFFFFFFFF).withValues(alpha: theme.isDark ? 0.14 : 0.55) : theme.border,
              width: glass ? 0.8 : 1,
            ),
          ),
          position: DecorationPosition.background,
          child: DecoratedBox(
            // Specular sheen across the top-left of the glass.
            decoration: BoxDecoration(
              borderRadius: r,
              gradient: glass
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        const Color(0xFFFFFFFF).withValues(alpha: theme.isDark ? 0.07 : 0.35),
                        const Color(0x00FFFFFF),
                      ],
                    )
                  : null,
            ),
            child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
          ),
        ),
      ),
    );
  }
}
