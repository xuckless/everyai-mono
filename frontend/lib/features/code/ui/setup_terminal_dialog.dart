// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' as m;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../../core/ui/selection.dart';
import '../drivers/detection/cli_state.dart';
import '../drivers/detection/install_commands.dart';
import '../drivers/driver.dart';
import '../drivers/driver_registry.dart';
import '../environments/exec_env.dart';
import '../panes/setup_terminal.dart';
import '../settings/context_files_stub.dart' if (dart.library.io) '../settings/context_files_io.dart' as home;
import 'panes/terminal_font.dart';

/// Opens the setup terminal for [driver]: the vendor's install line for this system typed at a prompt (not run),
/// and, once the CLI is there, its own sign-in. [env] is where the shell runs. With [signIn] (the CLI is installed
/// but signed out) the login command is typed instead, as long as the last check knows where the CLI is.
Future<void> showSetupTerminal(
  BuildContext context, {
  required HarnessDriver driver,
  ExecEnv env = HostEnv.instance,
  bool signIn = false,
}) => showGeneralDialog<void>(
  context: context,
  useRootNavigator: true,
  barrierDismissible: false,
  barrierLabel: 'Close setup',
  barrierColor: const Color(0x66000000),
  pageBuilder: (_, _, _) => SetupTerminalDialog(driver: driver, env: env, signIn: signIn),
);

/// [path] as one word for the shell of [os].
String shellWord(String path, SetupOs os) {
  if (os == SetupOs.windows) return path.contains(' ') ? '"$path"' : path;
  return RegExp(r'^[\w@%+=:,./-]+$').hasMatch(path) ? path : "'${path.replaceAll("'", r"'\''")}'";
}

class SetupTerminalDialog extends ConsumerStatefulWidget {
  const SetupTerminalDialog({super.key, required this.driver, required this.env, this.signIn = false});

  final HarnessDriver driver;
  final ExecEnv env;
  final bool signIn;

  @override
  ConsumerState<SetupTerminalDialog> createState() => _SetupTerminalDialogState();
}

class _SetupTerminalDialogState extends ConsumerState<SetupTerminalDialog> {
  final _view = TerminalController();
  late final SetupTerminal _shell;
  late final SetupOs _os;
  late final SetupCommands? _commands;
  var _checking = false;
  late final bool _startsSignedIn;

  @override
  void initState() {
    super.initState();
    _os = setupOsFor(widget.env.isHost, defaultTargetPlatform) ?? SetupOs.linux;
    _commands = setupCommandsFor(widget.driver.info.id, _os);
    _shell = SetupTerminal(
      env: widget.env,
      starter: ref.read(setupShellStarterProvider),
      home: home.homeDir() ?? '.',
      settle: ref.read(setupSettleProvider),
    );
    final status = ref.read(driverStatusesProvider).value?[widget.driver.info.id];
    final path = widget.env.isHost ? status?.path : null;
    _startsSignedIn = widget.signIn && path != null && _commands != null;
    final first = _startsSignedIn ? _loginLine(path!) : _commands?.install;
    // After the first layout, so the shell starts at the view's size.
    WidgetsBinding.instance.endOfFrame.then((_) {
      if (mounted) unawaited(_shell.start(first: first));
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
      await ref.read(driverStatusesProvider.notifier).refresh(reloadShell: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _close() async {
    final navigator = Navigator.of(context);
    final statuses = ref.read(driverStatusesProvider.notifier);
    _shell.dispose();
    navigator.pop();
    await statuses.refresh(reloadShell: true);
  }

  /// Types the CLI's own sign-in with the path the last check found: the terminal's PATH is older than the install.
  void _signIn(DriverStatus status) {
    final path = status.path;
    if (path == null) return;
    _shell.type(_loginLine(path));
  }

  String _loginLine(String path) => [shellWord(path, _os), ...?_commands?.login].join(' ');

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
    final id = widget.driver.info.id;
    final status = ref.watch(driverStatusesProvider.select((s) => s.value?[id]));
    // The check runs on this computer, so it says nothing about another environment: the user signs in there by hand.
    final state = status == null || !widget.env.isHost ? null : cliStateOf(status);
    final ready = state == CliState.ready;
    final canSignIn = state == CliState.signIn && status!.path != null;
    final commands = _commands;
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
                  boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 60, offset: Offset(0, 30))],
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
                                Expanded(
                                  child: Text(
                                    '${_startsSignedIn ? 'Sign in to' : 'Set up'} ${widget.driver.info.label}',
                                    style: theme.type.title,
                                  ),
                                ),
                                AdaptiveIconButton(
                                  key: const ValueKey('setup.close'),
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
                                if (!widget.env.isHost)
                                  Text(
                                    'Inside: ${widget.env.label}',
                                    key: const ValueKey('setup.env'),
                                    style: theme.type.caption.tint(theme.textMuted),
                                  ),
                                Text(
                                  _startsSignedIn
                                      ? "This is the CLI's own sign-in. It is typed below but not run: press Enter to run it."
                                      : commands == null
                                      ? 'No install line for this system. Install it yourself, then check again.'
                                      : "This is the vendor's own install line. It is typed below but not run: press "
                                            'Enter to run it. If it asks for a password, type it in the terminal.',
                                  style: theme.type.caption.tint(theme.textMuted),
                                ),
                                if (commands != null && !_startsSignedIn) ...[
                                  const SizedBox(height: 6),
                                  AdaptiveSelectionArea(
                                    child: Text(
                                      commands.install,
                                      key: const ValueKey('setup.command'),
                                      style: theme.type.caption.mono.tint(theme.text),
                                    ),
                                  ),
                                  if (!commands.verified)
                                    Text(
                                      "Not checked against the vendor's page yet: ${commands.source}",
                                      key: const ValueKey('setup.unverified'),
                                      style: theme.type.caption.tint(theme.textMuted),
                                    ),
                                ],
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
                                Expanded(
                                  child: Text(
                                    ready
                                        ? 'Ready: ${widget.driver.info.label} is set up.'
                                        : canSignIn
                                        ? 'Installed. Sign in next.'
                                        : !widget.env.isHost
                                        ? 'When the install is done, sign in by typing the CLI there.'
                                        : 'When the install is done, check again.',
                                    key: const ValueKey('setup.state'),
                                    style: theme.type.caption.tint(ready ? theme.success : theme.textMuted),
                                  ),
                                ),
                                if (widget.env.isHost)
                                  AdaptiveButton(
                                    key: const ValueKey('setup.check'),
                                    label: 'Check again',
                                    emphasis: ButtonEmphasis.secondary,
                                    busy: _checking,
                                    onPressed: _checking ? null : _check,
                                  ),
                                if (canSignIn) ...[
                                  const SizedBox(width: 8),
                                  AdaptiveButton(
                                    key: const ValueKey('setup.sign-in'),
                                    label: 'Sign in',
                                    onPressed: () => _signIn(status),
                                  ),
                                ],
                                const SizedBox(width: 8),
                                AdaptiveButton(
                                  key: const ValueKey('setup.done'),
                                  label: 'Close',
                                  emphasis: ready ? ButtonEmphasis.primary : ButtonEmphasis.plain,
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
