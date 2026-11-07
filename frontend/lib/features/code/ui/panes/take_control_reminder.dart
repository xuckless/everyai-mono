// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../harness/everyai/browser_io.dart';
import '../../live/app_sources.dart';
import '../../live/device_screen.dart';
import '../../live/flutter_app_io.dart';
import '../../live/live_browsers.dart';
import '../../live/live_session.dart';
import '../../live/react_native_io.dart';

/// Session [sessionId]'s live sources (its browser, its apps) among [asking]: the ones whose agent waits for the
/// user to give control back, with what to call each.
List<({LiveControl control, String what})> waitingControls(String sessionId, List<LiveControl> asking) {
  if (asking.isEmpty) return const [];
  final mine = <({LiveControl control, String what})>[
    if (LiveBrowsers.of(sessionId) case final b?) (control: b.control, what: 'the browser'),
    for (final app in AppSources.running([sessionId]))
      if (_controlOf(AppSources.driverOf(app)) case final c?) (control: c, what: app.label),
  ];
  return [
    for (final m in mine)
      if (asking.any((a) => identical(a, m.control))) m,
  ];
}

LiveControl? _controlOf(Object? driver) => switch (driver) {
  final HeadlessBrowser b => b.control,
  final FlutterApp a => a.control,
  final ReactNativeApp a => a.control,
  final DeviceScreen s => s.control,
  _ => null,
};

/// A reminder above the composer while the user holds a live source the agent wants back ("Agent would like to
/// take control of the browser"): the user took control in the Preview and may have forgotten, while the agent's
/// next step waits. Allow gives control back, like Give back in the Preview. Nothing while no source waits.
///
/// No state of its own: it follows [LiveControl.asking] and each source's [LiveControl.phase].
class TakeControlReminder extends StatelessWidget {
  const TakeControlReminder({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<LiveControl>>(
    valueListenable: LiveControl.asking,
    builder: (context, asking, _) {
      final waiting = waitingControls(sessionId, asking);
      if (waiting.isEmpty) return const SizedBox.shrink();
      final theme = EveryTheme.of(context);
      final what = {for (final w in waiting) w.what}.join(' and ');
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Container(
          key: const ValueKey('take-control-reminder'),
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(
            color: theme.accentBg,
            border: Border.all(color: theme.accent.withValues(alpha: 0.6)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              AdaptiveIcon(EveryIcon.display, size: 15, color: theme.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: 'Agent would like to take control of $what', style: theme.type.callout.semibold),
                      TextSpan(
                        text: '  · you took it in the Preview, and its next step is waiting',
                        style: theme.type.caption.tint(theme.textMuted),
                      ),
                    ],
                  ),
                  style: theme.type.callout.tint(theme.text),
                ),
              ),
              const SizedBox(width: 8),
              AdaptiveButton(
                key: const ValueKey('take-control-reminder.allow'),
                label: 'Allow',
                onPressed: () {
                  for (final w in waiting) {
                    w.control.giveBack();
                  }
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}
