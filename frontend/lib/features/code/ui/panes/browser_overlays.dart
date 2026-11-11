// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/motion/motion.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/anchored_popover.dart';
import '../../../../core/ui/every_icons.dart';
import '../../harness/everyai/browser_io.dart';
import '../../harness/everyai/screen_tools_io.dart' show browserOpenRefusal;

// The Preview browser's own chrome for people: tabs, the page's dialogs, find, the right-click menu and downloads.

/// The session's tabs, shown once a page opened another (a pop-up, a link to a new tab).
class BrowserTabStrip extends StatelessWidget {
  const BrowserTabStrip({super.key, required this.browser});

  final BrowserPage browser;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return ValueListenableBuilder<List<BrowserTab>>(
      valueListenable: browser.tabs,
      builder: (context, tabs, _) {
        if (tabs.length < 2) return const SizedBox.shrink();
        return SizedBox(
          height: 30,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final t in tabs)
                _TabChip(
                  key: ValueKey(t.id),
                  title: t.title.isNotEmpty ? t.title : (Uri.tryParse(t.url)?.host ?? t.url),
                  active: t.id == browser.activeTab,
                  onTap: () => unawaited(browser.switchTab(t.id).catchError((Object _) {})),
                  onClose: () => unawaited(browser.closeTab(t.id).catchError((Object _) {})),
                  theme: theme,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    super.key,
    required this.title,
    required this.active,
    required this.onTap,
    required this.onClose,
    required this.theme,
  });

  final String title;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final EveryTheme theme;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 4, top: 2, bottom: 2),
    child: Pressable(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 200),
        padding: const EdgeInsets.only(left: 10, right: 2),
        decoration: BoxDecoration(
          color: active ? theme.surfaceRaised : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: active ? theme.border : const Color(0x00000000)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.type.caption.tint(active ? theme.text : theme.textMuted),
              ),
            ),
            AdaptiveIconButton(icon: EveryIcon.close, tooltip: 'Close tab', size: 12, onPressed: onClose),
          ],
        ),
      ),
    ),
  );
}

/// The page's dialog (alert, confirm, prompt, "leave this page?") over the page: the page waits until it is
/// answered, here or by the agent. A prompt's field takes typing and paste like any field.
class PageDialogPanel extends StatefulWidget {
  const PageDialogPanel({super.key, required this.browser, required this.dialog});

  final BrowserPage browser;
  final PageDialog dialog;

  @override
  State<PageDialogPanel> createState() => _PageDialogPanelState();
}

class _PageDialogPanelState extends State<PageDialogPanel> {
  late final _text = TextEditingController(text: widget.dialog.defaultPrompt);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _answer(bool accept) => unawaited(
    widget.browser
        .answerDialog(accept: accept, text: widget.dialog.type == 'prompt' && accept ? _text.text : null)
        .catchError((Object _) {}),
  );

  @override
  Widget build(BuildContext context) {
    final d = widget.dialog;
    final host = Uri.tryParse(widget.browser.page.value.url)?.host ?? '';
    final leave = d.type == 'beforeunload';
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => _answer(false),
        const SingleActivator(LogicalKeyboardKey.enter): () => _answer(true),
      },
      child: Focus(
        focusNode: d.type == 'prompt' ? null : _focus,
        child: KitDialog(
          title: leave ? 'Leave this page?' : (host.isEmpty ? 'The page says' : '$host says'),
          width: 380,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (d.message.isNotEmpty) Text(leave ? 'Changes you made may not be saved.' : d.message),
              if (d.type == 'prompt') ...[
                const SizedBox(height: 10),
                AdaptiveTextField(controller: _text, focusNode: _focus, onSubmitted: (_) => _answer(true)),
              ],
            ],
          ),
          actions: [
            if (d.type != 'alert')
              AdaptiveButton(
                label: leave ? 'Stay' : 'Cancel',
                emphasis: ButtonEmphasis.secondary,
                onPressed: () => _answer(false),
              ),
            AdaptiveButton(label: leave ? 'Leave' : 'OK', onPressed: () => _answer(true)),
          ],
        ),
      ),
    );
  }
}

/// ⌘F: find in the page, with the number of matches, Enter / Shift+Enter for the next and previous.
class BrowserFindBar extends StatefulWidget {
  const BrowserFindBar({super.key, required this.browser, required this.onClose});

  final BrowserPage browser;
  final VoidCallback onClose;

  @override
  State<BrowserFindBar> createState() => _BrowserFindBarState();
}

class _BrowserFindBarState extends State<BrowserFindBar> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  int? _count;

  /// Answers to an older query are dropped.
  var _gen = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _find({bool backwards = false}) async {
    final gen = ++_gen;
    final n = await widget.browser.findText(_text.text, backwards: backwards).catchError((Object _) => 0);
    if (mounted && gen == _gen) setState(() => _count = _text.text.isEmpty ? null : n);
  }

  void _close() {
    unawaited(widget.browser.findText('').catchError((Object _) => 0));
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.enter, shift: true): () => _find(backwards: true),
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
        child: Row(
          children: [
            Expanded(
              child: AdaptiveTextField(
                controller: _text,
                focusNode: _focus,
                placeholder: 'Find in page',
                onChanged: (_) => _find(),
                onSubmitted: (_) {
                  unawaited(_find());
                  _focus.requestFocus();
                },
              ),
            ),
            if (_count != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  _count == 0 ? 'No matches' : '$_count match${_count == 1 ? '' : 'es'}',
                  style: theme.type.caption.tint(theme.textMuted),
                ),
              ),
            AdaptiveIconButton(
              icon: EveryIcon.chevronUp,
              tooltip: 'Previous',
              size: 15,
              onPressed: () => _find(backwards: true),
            ),
            AdaptiveIconButton(icon: EveryIcon.chevronDown, tooltip: 'Next', size: 15, onPressed: _find),
            AdaptiveIconButton(icon: EveryIcon.close, tooltip: 'Close', size: 15, onPressed: _close),
          ],
        ),
      ),
    );
  }
}

/// One item of the page's right-click menu.
typedef PageMenuItem = ({String label, VoidCallback? onSelected});

/// The items of the right-click menu for what is under the pointer ([at]): editing, links, pictures, and asking the
/// agent about the element. [ask] puts a line about it in the composer.
List<PageMenuItem> pageMenuItems(BrowserPage b, PageContext at, {required void Function(String text) ask}) {
  Future<void> copy(String text) => Clipboard.setData(ClipboardData(text: text));
  final page = b.page.value;
  return [
    if (at.selection.isNotEmpty) (label: 'Copy', onSelected: () => unawaited(copy(at.selection))),
    if (at.editable && at.selection.isNotEmpty)
      (
        label: 'Cut',
        onSelected: () {
          unawaited(copy(at.selection));
          unawaited(b.userCommand('cut').catchError((Object _) {}));
        },
      ),
    if (at.editable)
      (
        label: 'Paste',
        onSelected: () => unawaited(
          Clipboard.getData(Clipboard.kTextPlain).then((d) {
            final text = d?.text;
            if (text != null && text.isNotEmpty) return b.userText(text);
          }),
        ),
      ),
    if (at.editable)
      (label: 'Select all', onSelected: () => unawaited(b.userCommand('selectAll').catchError((Object _) {}))),
    if (at.link case final link?) ...[
      // The page picks the address: the same guard as the agent's open (credential files, look-alike sites).
      (
        label: 'Open link in new tab',
        onSelected: browserOpenRefusal(link) != null
            ? null
            : () => unawaited(b.openTab(link).catchError((Object _) {})),
      ),
      (label: 'Copy link address', onSelected: () => unawaited(copy(link))),
    ],
    if (at.image case final image?) (label: 'Copy image address', onSelected: () => unawaited(copy(image))),
    if (at.selection.isEmpty && !at.editable && at.link == null) ...[
      (label: 'Back', onSelected: page.canBack ? () => unawaited(b.back().catchError((Object _) {})) : null),
      (label: 'Forward', onSelected: page.canForward ? () => unawaited(b.forward().catchError((Object _) {})) : null),
      (label: 'Reload', onSelected: () => unawaited(b.reload().catchError((Object _) {}))),
    ],
    (label: 'Ask the agent about this', onSelected: () => ask('In the Preview at ${page.url}, ${at.description}: ')),
  ];
}

/// The right-click menu, drawn at the pointer inside the page view; any tap outside or Escape closes it.
class PageContextMenu extends StatelessWidget {
  const PageContextMenu({super.key, required this.items, required this.onClose});

  final List<PageMenuItem> items;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
    child: Focus(
      autofocus: true,
      child: SizedBox(
        width: 220,
        child: GlassSurface(
          level: GlassLevel.thick,
          radius: 12,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, item) in items.indexed)
                  PopoverRow(
                    key: ValueKey('page.menu.${item.label}'),
                    title: item.label,
                    onTap: item.onSelected == null
                        ? null
                        : () {
                            onClose();
                            item.onSelected!();
                          },
                  ).rowIn(i),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The session's downloads: a button with the newest's progress, a menu to open each or show it in its folder.
class BrowserDownloadsButton extends StatelessWidget {
  const BrowserDownloadsButton({super.key, required this.browser});

  final BrowserPage browser;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return ValueListenableBuilder<List<BrowserDownload>>(
      valueListenable: browser.downloads,
      builder: (context, list, _) {
        if (list.isEmpty) return const SizedBox.shrink();
        final running = list.where((d) => d.state == 'inProgress').length;
        return AdaptiveMenuButton(
          tooltip: 'Downloads',
          width: 300,
          actions: [
            for (final d in list.reversed)
              MenuAction(
                label: switch (d.state) {
                  'inProgress' => '${d.name}  ${(d.progress * 100).round()}%',
                  'canceled' => '${d.name}  (canceled)',
                  _ => d.name,
                },
                onSelected: d.path == null || d.state != 'completed' ? () {} : () => _reveal(d.path!),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  EveryIcon.download.of(theme.design),
                  size: 16,
                  color: running > 0 ? theme.accent : theme.textMuted,
                ),
                if (running > 0) ...[
                  const SizedBox(width: 3),
                  Text('$running', style: theme.type.caption.tint(theme.accent)),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// Shows [path] in its folder (Finder, Explorer, the file manager).
  static void _reveal(String path) {
    final (cmd, args) = Platform.isMacOS
        ? ('open', ['-R', path])
        : Platform.isWindows
        ? ('explorer', ['/select,', path])
        : ('xdg-open', [File(path).parent.path]);
    unawaited(Process.run(cmd, args).then((_) {}, onError: (Object _) {}));
  }
}
