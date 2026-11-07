import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart'
    as m
    show TextField, InputDecoration, InputBorder, Tooltip, Material, MaterialType;

import '../motion/motion.dart';
import '../theme/every_theme.dart';
import 'every_icons.dart';

/// A list of short entries in the style of macOS's Login Items: a framed table with column headers, striped rows
/// that select on click, and a + / − bar along the bottom. + adds a row typed in place (Return keeps it, Esc
/// drops it); − or Delete removes the selected row. Used wherever the app once asked for comma- or
/// line-separated text.
class KitListEditor extends StatefulWidget {
  const KitListEditor({
    super.key,
    required this.items,
    required this.onChanged,
    this.itemLabel = 'Item',
    this.kindLabel,
    this.kindOf,
    this.display,
    this.placeholder = 'Add an item',
    this.empty = 'None yet',
    this.validate,
    this.onReset,
    this.resetLabel = 'Defaults',
    this.maxHeight = 240,
  });

  final List<String> items;

  /// The whole new list after an add or a remove.
  final ValueChanged<List<String>> onChanged;

  /// Header of the first column.
  final String itemLabel;

  /// Header of the second column; null for one column.
  final String? kindLabel;

  /// The second column's text for an entry.
  final String Function(String item)? kindOf;

  /// How an entry reads in its row (default: as stored).
  final String Function(String item)? display;

  /// Hint in the row being typed.
  final String placeholder;

  /// Shown in the table while it has no rows.
  final String empty;

  /// Why a typed entry can't be added, or null when it can. Duplicates are refused on their own.
  final String? Function(String text)? validate;

  /// A button at the bar's right that restores the defaults; null for none.
  final VoidCallback? onReset;
  final String resetLabel;

  /// The rows scroll past this height.
  final double maxHeight;

  @override
  State<KitListEditor> createState() => _KitListEditorState();
}

class _KitListEditorState extends State<KitListEditor> {
  /// The selected row's item (items are unique), not its index: a list changed from outside can't move the selection
  /// onto another row, so Delete never removes a row the user didn't pick.
  String? _selectedItem;
  int? get _selected {
    final i = _selectedItem == null ? -1 : widget.items.indexOf(_selectedItem!);
    return i < 0 ? null : i;
  }

  bool _adding = false;
  String? _error;
  final _text = TextEditingController();
  final _field = FocusNode();
  final _table = FocusNode(debugLabel: 'list-editor');

  @override
  void didUpdateWidget(KitListEditor old) {
    super.didUpdateWidget(old);
    if (_selectedItem case final item? when !widget.items.contains(item)) _selectedItem = null;
  }

  @override
  void dispose() {
    _text.dispose();
    _field.dispose();
    _table.dispose();
    super.dispose();
  }

  void _startAdding() {
    setState(() {
      _adding = true;
      _error = null;
      _selectedItem = null;
      _text.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _field.requestFocus());
  }

  void _commit() {
    final text = _text.text.trim();
    if (text.isEmpty) return _cancel();
    final error = widget.items.contains(text) ? 'Already in the list' : widget.validate?.call(text);
    if (error != null) return setState(() => _error = error);
    widget.onChanged([...widget.items, text]);
    setState(() {
      _adding = false;
      _error = null;
      _selectedItem = text;
    });
    _table.requestFocus();
  }

  void _cancel() {
    setState(() {
      _adding = false;
      _error = null;
    });
    _table.requestFocus();
  }

  void _remove() {
    final i = _selected;
    if (i == null) return;
    final rest = [...widget.items]..removeAt(i);
    widget.onChanged(rest);
    setState(() => _selectedItem = rest.isEmpty ? null : rest[i == 0 ? 0 : i - 1]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final two = widget.kindLabel != null && widget.kindOf != null;
    final cell = theme.type.callout;

    Widget columns(Widget first, Widget? second) => Row(
      children: [
        Expanded(flex: 3, child: first),
        if (two) Expanded(flex: 2, child: second ?? const SizedBox()),
      ],
    );

    Widget row(int i) {
      final item = widget.items[i];
      final selected = _selected == i;
      final fg = selected ? theme.onPrimary : theme.text;
      return GestureDetector(
        key: ValueKey('list-editor.row.$i'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _table.requestFocus();
          setState(() {
            _selectedItem = selected ? null : item;
            if (_adding) _adding = false;
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected
                ? theme.primary
                : i.isOdd
                ? theme.hover
                : null,
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.centerLeft,
          child: columns(
            Text(
              widget.display?.call(item) ?? item,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: cell.tint(fg),
            ),
            two
                ? Text(
                    widget.kindOf!(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: cell.tint(selected ? theme.onPrimary : theme.textMuted),
                  )
                : null,
          ),
        ),
      );
    }

    final adding = Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: theme.well,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _error == null ? theme.accent.withValues(alpha: 0.6) : theme.danger),
      ),
      alignment: Alignment.centerLeft,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancel},
        // TextField needs a Material ancestor, which a dialog may not have.
        child: m.Material(
          type: m.MaterialType.transparency,
          child: m.TextField(
            key: const ValueKey('list-editor.input'),
            controller: _text,
            focusNode: _field,
            style: cell.tint(theme.text),
            cursorColor: theme.accent,
            onSubmitted: (_) => _commit(),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: m.InputDecoration(
              isDense: true,
              border: m.InputBorder.none,
              contentPadding: EdgeInsets.zero,
              hintText: widget.placeholder,
              hintStyle: cell.tint(theme.textSubtle),
            ),
          ),
        ),
      ),
    );

    final bar = Row(
      children: [
        _BarButton(
          key: const ValueKey('list-editor.add'),
          icon: EveryIcon.add,
          tooltip: 'Add',
          onTap: _adding ? _commit : _startAdding,
        ),
        Container(width: 1, height: 14, color: theme.border),
        _BarButton(
          key: const ValueKey('list-editor.remove'),
          icon: EveryIcon.minus,
          tooltip: 'Remove',
          onTap: _selected == null ? null : _remove,
        ),
        const SizedBox(width: 8),
        if (_error case final e?)
          Expanded(
            child: Text(e, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.type.caption.tint(theme.danger)),
          )
        else
          const Spacer(),
        if (widget.onReset case final reset?)
          Pressable(
            key: const ValueKey('list-editor.reset'),
            onTap: reset,
            semanticLabel: widget.resetLabel,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(widget.resetLabel, style: theme.type.caption.tint(theme.textMuted)),
            ),
          ),
      ],
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.delete): _remove,
        const SingleActivator(LogicalKeyboardKey.backspace): _remove,
      },
      child: Focus(
        focusNode: _table,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.surfaceRaised,
            borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
            border: Border.all(color: theme.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 9, 18, 7),
                child: columns(
                  Text(widget.itemLabel, style: theme.type.caption.tint(theme.textMuted)),
                  two ? Text(widget.kindLabel!, style: theme.type.caption.tint(theme.textMuted)) : null,
                ),
              ),
              Container(height: 1, color: theme.border),
              ConstrainedBox(
                constraints: BoxConstraints(minHeight: 72, maxHeight: widget.maxHeight),
                child: widget.items.isEmpty && !_adding
                    ? Center(child: Text(widget.empty, style: theme.type.caption.tint(theme.textSubtle)))
                    : ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.all(6),
                        children: [for (var i = 0; i < widget.items.length; i++) row(i), if (_adding) adding.settle()],
                      ),
              ),
              Container(height: 1, color: theme.border),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), child: bar),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({super.key, required this.icon, required this.tooltip, required this.onTap});

  final EveryIcon icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return m.Tooltip(
      message: tooltip,
      child: Pressable(
        onTap: onTap,
        semanticLabel: tooltip,
        child: SizedBox(
          width: 30,
          height: 28,
          child: Icon(icon.data, size: 15, color: onTap == null ? theme.textSubtle.withValues(alpha: 0.5) : theme.text),
        ),
      ),
    );
  }
}
