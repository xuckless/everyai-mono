// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui/adaptive.dart';
import '../code_settings_providers.dart';
import '../domain/code_session.dart' show everyaiHarnessName;
import '../drivers/detection/cli_state.dart';
import '../drivers/detection/install_commands.dart';
import '../drivers/driver.dart';
import '../drivers/driver_registry.dart';
import '../environments/exec_env.dart';
import '../panes/pty.dart' show shellSupported;
import 'setup_terminal_dialog.dart';

/// Opens the setup terminal; tests replace it.
typedef SetupOpener = Future<void> Function(BuildContext context, HarnessDriver driver, ExecEnv env, {bool signIn});

final setupOpenerProvider = Provider<SetupOpener>(
  (ref) =>
      (context, driver, env, {signIn = false}) => showSetupTerminal(context, driver: driver, env: env, signIn: signIn),
);

/// "Set up" (the CLI is missing or broken) or "Sign in" (it says it is signed out) on a harness row; nothing where
/// there is nothing to do or no way to do it: the own harness, a ready CLI, a phone, no line for this system, or a
/// subscription CLI the user has not agreed to use yet.
class SetupButton extends ConsumerWidget {
  const SetupButton({
    super.key,
    required this.driver,
    required this.status,
    this.env = HostEnv.instance,
    this.offerMissing = true,
  });

  final HarnessDriver driver;

  /// The last check, null while it runs.
  final DriverStatus? status;
  final ExecEnv env;

  /// Whether a CLI that is not there at all gets Set up. Off (onboarding): only when the vendor's desktop app is
  /// found. A check that failed never offers it either way ([cliStateOf]).
  final bool offerMissing;

  /// The label for [status], or null when there is nothing to offer. [appFound]: a missing CLI may be set up.
  static String? labelFor(DriverStatus? status, {bool appFound = true}) {
    if (status == null) return null;
    return switch (cliStateOf(status, appFound: appFound)) {
      CliState.setUp => 'Set up',
      CliState.signIn => 'Sign in',
      CliState.ready || CliState.absent => null,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = driver.info;
    final scan = ref.watch(driverStatusesProvider.notifier).appScan;
    ref.watch(driverStatusesProvider);
    final label = labelFor(status, appFound: offerMissing || (env.isHost && scan.offersSetUp(info.id)));
    final os = setupOsFor(env.isHost, defaultTargetPlatform);
    if (label == null || os == null || !shellSupported || info.id == everyaiHarnessName) return const SizedBox.shrink();
    if (setupCommandsFor(info.id, os) == null) return const SizedBox.shrink();
    if (info.needsConsent && !ref.watch(codeSettingsProvider.select((s) => s.ownClis.contains(info.consentId)))) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: AdaptiveButton(
        key: ValueKey('setup.${info.id}${env.isHost ? '' : '.${env.id}'}'),
        label: label,
        emphasis: ButtonEmphasis.secondary,
        onPressed: () => ref.read(setupOpenerProvider)(context, driver, env, signIn: label == 'Sign in'),
      ),
    );
  }
}
