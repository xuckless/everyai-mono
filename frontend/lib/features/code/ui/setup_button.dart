// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui/adaptive.dart';
import '../code_settings_providers.dart';
import '../domain/code_session.dart' show everyaiHarnessName;
import '../drivers/detection/install_commands.dart';
import '../drivers/driver.dart';
import '../environments/exec_env.dart';
import '../panes/pty.dart' show shellSupported;
import 'setup_terminal_dialog.dart';

/// Opens the setup terminal; tests replace it.
typedef SetupOpener = Future<void> Function(BuildContext context, HarnessDriver driver, ExecEnv env);

final setupOpenerProvider = Provider<SetupOpener>(
  (ref) =>
      (context, driver, env) => showSetupTerminal(context, driver: driver, env: env),
);

/// "Set up" (the CLI is missing or broken) or "Sign in" (it says it is signed out) on a harness row; nothing where
/// there is nothing to do or no way to do it: the own harness, a ready CLI, a phone, no line for this system, or a
/// subscription CLI the user has not agreed to use yet.
class SetupButton extends ConsumerWidget {
  const SetupButton({super.key, required this.driver, required this.status, this.env = HostEnv.instance});

  final HarnessDriver driver;

  /// The last check, null while it runs.
  final DriverStatus? status;
  final ExecEnv env;

  /// The label for [status], or null when there is nothing to offer.
  static String? labelFor(DriverStatus? status) {
    if (status == null) return null;
    if (!status.installed) return 'Set up';
    if (status.signedIn == false) return 'Sign in';
    return status.problem == null ? null : 'Set up';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = driver.info;
    final label = labelFor(status);
    final os = SetupOs.of(defaultTargetPlatform);
    if (label == null || os == null || !shellSupported || info.id == everyaiHarnessName) return const SizedBox.shrink();
    if (setupCommandsFor(info.id, os) == null) return const SizedBox.shrink();
    if (info.needsConsent && !ref.watch(codeSettingsProvider.select((s) => s.ownClis.contains(info.consentId)))) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: AdaptiveButton(
        key: ValueKey('setup.${info.id}'),
        label: label,
        emphasis: ButtonEmphasis.secondary,
        onPressed: () => ref.read(setupOpenerProvider)(context, driver, env),
      ),
    );
  }
}
