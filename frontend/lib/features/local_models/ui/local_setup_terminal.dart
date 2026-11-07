// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter/material.dart' as m;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../../core/ui/selection.dart';
import '../../code/environments/exec_env.dart';
import '../../code/panes/setup_terminal.dart';
import '../../code/settings/context_files_stub.dart'
    if (dart.library.io) '../../code/settings/context_files_io.dart'
    as home;
import '../../code/ui/panes/terminal_font.dart';

/// Opens our terminal with [line] typed at the prompt but not run (the user presses Enter, and types any password
/// there): Ollama's official install, or `sudo fm license` for Apple's terms. [onCheck] runs on Check again and when
/// the dialog closes (a rescan).
Future<void> showLocalSetupTerminal(
  BuildContext context, {
  required String title,
  required String line,
  required String explanation,
  String? source,
  required Future<void> Function() onCheck,
}) => showKitDialog<void>(
  context,
  dismissible: false,
  builder: (_) =>
      LocalSetupTerminalDialog(title: title, line: line, explanation: explanation, source: source, onCheck: onCheck),
);

class LocalSetupTerminalDialog extends ConsumerStatefulWidget {
  const LocalSetupTerminalDialog({
    super.key,
    required this.title,
    required this.line,
    required this.explanation,
    this.source,
    required this.onCheck,
  });

  final String title;
  final String line;
  final String explanation;
  final String? source;
  final Future<void> Function() onCheck;

  @override
  ConsumerState<LocalSetupTerminalDialog> createState() => _LocalSetupTerminalDialogState();
}

class _LocalSetupTerminalDialogState extends ConsumerState<LocalSetupTerminalDialog> {
  final _view = TerminalController();
  late final SetupTerminal _shell;
  var _checking = false;

  @override
  void initState() {
    super.initState();
    _shell = SetupTerminal(
      env: HostEnv.instance,
      starter: ref.read(setupShellStarterProvider),
      home: home.homeDir() ?? '.',
      settle: ref.read(setupSettleProvider),
    );
    WidgetsBinding.instance.endOfFrame.then((_) {
      if (mounted) unawaited(_shell.start(first: widget.line));
    });
  }

  @override
  void dispose() {
    _view.dispose();
    _shell.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    try {
      await widget.onCheck();
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// Esc and Close can both fire: the dialog closes once, so the page under it isn't popped too.
  var _closed = false;

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    final navigator = Navigator.of(context);
    _shell.dispose();
    navigator.pop();
    await widget.onCheck();
  }

  Future<void> _copyOrPaste() async {
    if (_view.selection case final selection?) {
      await Clipboard.setData(ClipboardData(text: _shell.terminal.buffer.getText(selection)));
      _view.clearSelection();
    } else if ((await Clipboard.getData(Clipboard.kTextPlain))?.text case final text?) {
      _shell.terminal.paste(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: FocusScope(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760, maxHeight: 560),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(EveryTheme.panelRadius),
                  boxShadow: theme.shadowPop,
                ),
                child: GlassSurface(
                  level: GlassLevel.thick,
                  radius: EveryTheme.panelRadius,
                  child: m.Material(
                    type: m.MaterialType.transparency,
                    child: DefaultTextStyle(
                      style: theme.type.body.tint(theme.text),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
                            child: Row(
                              children: [
                                Expanded(child: Text(widget.title, style: theme.type.title)),
                                AdaptiveIconButton(
                                  key: const ValueKey('local.setup.close'),
                                  icon: EveryIcon.close,
                                  tooltip: 'Close',
                                  onPressed: _close,
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(widget.explanation, style: theme.type.caption.tint(theme.textMuted)),
                                const SizedBox(height: 6),
                                AdaptiveSelectionArea(
                                  child: Text(
                                    widget.line,
                                    key: const ValueKey('local.setup.command'),
                                    style: theme.type.caption.mono.tint(theme.text),
                                  ),
                                ),
                                if (widget.source case final s?)
                                  Text('From $s', style: theme.type.caption.tint(theme.textMuted)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              child: ColoredBox(
                                color: TerminalThemes.defaultTheme.background,
                                child: TerminalView(
                                  _shell.terminal,
                                  controller: _view,
                                  autofocus: true,
                                  padding: const EdgeInsets.all(8),
                                  textStyle: TerminalStyle(
                                    fontFamily: 'GeistMono',
                                    fontFamilyFallback: terminalFontFallback,
                                    fontSize: theme.type.callout.fontSize!,
                                  ),
                                  onSecondaryTapDown: (_, _) => _copyOrPaste(),
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
                            child: Row(
                              children: [
                                const Spacer(),
                                AdaptiveButton(
                                  key: const ValueKey('local.setup.check'),
                                  label: 'Check again',
                                  emphasis: ButtonEmphasis.secondary,
                                  busy: _checking,
                                  onPressed: _checking ? null : _check,
                                ),
                                const SizedBox(width: 8),
                                AdaptiveButton(
                                  key: const ValueKey('local.setup.done'),
                                  label: 'Close',
                                  emphasis: ButtonEmphasis.plain,
                                  onPressed: _close,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
