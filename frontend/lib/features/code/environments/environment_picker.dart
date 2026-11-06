// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import 'environment_providers.dart';
import 'environment_statuses.dart';
import 'exec_env.dart';
import 'ssh_remote_form.dart';

/// The glyph for an environment: this computer, or a terminal for the rest
/// (no art per kind).
EveryIcon environmentIcon(ExecEnv env) => env.isHost ? EveryIcon.display : EveryIcon.command;

/// A popover that picks where a project runs: every environment found
/// (also those with no CLIs in them), then "Add SSH remote…" and "Rescan
/// environments". [child] is the trigger (the "Runs in" chip, a project's
/// ⋯); the project stays the one place the choice is kept ([onPick] stores it).
class EnvironmentMenu extends StatelessWidget {
  const EnvironmentMenu({super.key, required this.envId, required this.onPick, required this.child, this.width = 300});

  /// The environment now picked (`CodeProject.environment`).
  final String envId;
  final ValueChanged<String> onPick;
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) => AnchoredPopover(
    width: width,
    builder: (context, close) => EnvironmentPanel(envId: envId, onPick: onPick, close: close),
    child: child,
  );
}

/// The list inside [EnvironmentMenu]'s popover (a page of the sidebar's project menu too).
class EnvironmentPanel extends ConsumerStatefulWidget {
  const EnvironmentPanel({super.key, required this.envId, required this.onPick, required this.close});

  final String envId;
  final ValueChanged<String> onPick;
  final VoidCallback close;

  @override
  ConsumerState<EnvironmentPanel> createState() => _EnvironmentPanelState();
}

class _EnvironmentPanelState extends ConsumerState<EnvironmentPanel> {
  var _adding = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (_adding) {
      return SshRemoteForm(
        onCancel: () => setState(() => _adding = false),
        onSave: (remote) {
          ref.read(sshRemotesProvider.notifier).add(remote);
          setState(() => _adding = false);
        },
      );
    }
    final found = ref.watch(environmentsProvider);
    final envs = found.value ?? const <ExecEnv>[];
    Widget? check(bool on) => on ? AdaptiveIcon(EveryIcon.check, size: 14, color: theme.accent) : null;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PopoverHeader('Runs in'),
          // An environment that is gone stays listed, so the picked one is never missing from its own list.
          if (found.hasValue && !envs.any((e) => e.id == widget.envId))
            PopoverRow(
              key: ValueKey('environment.${widget.envId}'),
              title: widget.envId,
              subtitle: 'Not found right now. Rescan, or pick another.',
              selected: true,
              trailing: check(true),
            ),
          for (final e in envs)
            PopoverRow(
              key: ValueKey('environment.${e.id}'),
              leading: AdaptiveIcon(environmentIcon(e), size: 15, color: theme.textMuted),
              title: e.label,
              subtitle: !e.running
                  ? 'Stopped'
                  : e.kind == EnvKind.ssh
                  ? "Agents can't run here yet"
                  : e.note ?? (e.isHost ? null : e.kind.label),
              selected: e.id == widget.envId,
              trailing: check(e.id == widget.envId),
              onTap: () {
                widget.close();
                if (e.id != widget.envId) widget.onPick(e.id);
              },
            ),
          if (found.isLoading) const PopoverRow(title: 'Looking…'),
          PopoverRow(
            key: const ValueKey('environment.add-ssh'),
            leading: AdaptiveIcon(EveryIcon.add, size: 15, color: theme.textMuted),
            title: 'Add SSH remote…',
            onTap: () => setState(() => _adding = true),
          ),
          PopoverRow(
            key: const ValueKey('environment.rescan'),
            leading: AdaptiveIcon(EveryIcon.retry, size: 15, color: theme.textMuted),
            title: 'Rescan environments',
            onTap: () => rescanEnvironments(ref),
          ),
        ],
      ),
    );
  }
}

/// The "Runs in [Ubuntu (WSL) ▾]" chip of a project.
class EnvironmentChip extends ConsumerWidget {
  const EnvironmentChip({super.key, required this.envId, required this.onPick});

  final String envId;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    // The host never starts environment discovery just to be labelled.
    final env = watchEnvironment(ref, envId);
    // The id stands in while the list is loading or the environment is gone.
    final label = env?.label ?? (envId == 'host' ? EnvKind.host.label : envId);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Runs in', style: theme.type.callout.tint(theme.textMuted)),
        Flexible(
          child: EnvironmentMenu(
            envId: envId,
            onPick: onPick,
            child: Semantics(
              button: true,
              label: 'Runs in: $label',
              child: MenuTrigger(
                label,
                muted: true,
                leading: AdaptiveIcon(
                  env == null ? EveryIcon.display : environmentIcon(env),
                  size: 13,
                  color: theme.textMuted,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
