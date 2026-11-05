// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/selection.dart';
import '../../onboarding/domain/harness_rows.dart';
import '../../onboarding/git_bash_stub.dart';
import '../../onboarding/onboarding_harness_providers.dart';
import 'code_settings_section.dart' show harnessStatusLine;
import 'setup_button.dart';

/// One harness as the setup step and Settings → Harnesses show it: a dot, the name (with its environment when that
/// is not this computer), what was found, and one button by state (a check mark when Ready, Sign in, Set up).
/// [trailing] holds the screen's own control (consent); [footer] lines under the status.
class HarnessSetupRow extends ConsumerWidget {
  const HarnessSetupRow({
    super.key,
    required this.row,
    this.title,
    this.statusLine,
    this.unknownLine = "Couldn't check. Try Refresh.",
    this.offerMissing = true,
    this.trailing = const [],
    this.footer = const [],
  });

  final HarnessRow row;

  /// Replaces the name (the built-in agent's).
  final String? title;

  /// Replaces the default status line (the built-in agent's).
  final String? statusLine;

  /// The line for a check that timed out; a screen without Refresh says where to check again.
  final String unknownLine;

  /// Passed to [SetupButton.offerMissing].
  final bool offerMissing;
  final List<Widget> trailing;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final status = row.status;
    final line =
        statusLine ??
        switch (row.state) {
          RowState.checking => 'Checking…',
          RowState.unknown => unknownLine,
          _ => status == null ? 'Built in' : harnessStatusLine(row.id, status),
        };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: switch (row.state) {
                  RowState.ready => theme.success,
                  RowState.signIn || RowState.setUp => theme.accent,
                  _ => row.state == RowState.checking ? theme.textMuted : theme.border,
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title ?? row.title,
                  style: theme.type.callout.medium.tint(theme.text),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(line, style: theme.type.caption.tint(theme.textMuted)),
                ...footer,
              ],
            ),
          ),
          if (row.state == RowState.ready)
            Padding(
              key: ValueKey('harness.ready.${row.id}${row.keySuffix}'),
              padding: const EdgeInsets.only(left: 8),
              child: Text('Ready ✓', style: theme.type.caption.tint(theme.success)),
            ),
          SetupButton(driver: row.driver, status: status, env: row.env, offerMissing: offerMissing),
          ...trailing,
        ],
      ),
    );
  }
}

/// Windows only: the built-in agent runs its commands in Git Bash, which Git for Windows brings. It shows the
/// install line to copy; a Set up button that types it in d3's terminal is still to do (the terminal takes a driver).
class GitForWindowsNotice extends ConsumerWidget {
  const GitForWindowsNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(gitBashMissingProvider)) return const SizedBox.shrink();
    final theme = EveryTheme.of(context);
    return Padding(
      key: const ValueKey('harness.git-for-windows'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "EveryAI's own agent needs Git for Windows to run commands. Other agents don't.",
                  style: theme.type.callout.tint(theme.text),
                ),
                AdaptiveSelectionArea(
                  child: Text(
                    'To install: $gitForWindowsInstallLine',
                    style: theme.type.caption.mono.tint(theme.textMuted),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
