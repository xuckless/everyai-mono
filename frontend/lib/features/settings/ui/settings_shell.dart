import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';

/// Where the user was before they opened Settings, so Settings can send them
/// back (a Code session's gear, the chat they were in).
final settingsReturnProvider = NotifierProvider<SettingsReturn, String?>(SettingsReturn.new);

final class SettingsReturn extends Notifier<String?> {
  @override
  String? build() => null;

  /// Called on every navigation: remembers the last place outside Settings.
  void moved(String? from, String to) {
    if (!isSettingsLocation(to)) return;
    if (from != null && !isSettingsLocation(from)) state = from;
  }
}

bool isSettingsLocation(String location) {
  final path = Uri.parse(location).path;
  return path == Routes.settings || path.startsWith('${Routes.settings}/') || path == Routes.codeSettingsPath;
}

/// A Settings section in the list beside every settings page.
typedef SettingsSection = ({String label, String location, bool desktopOnly});

const List<SettingsSection> settingsSections = [
  (label: 'General', location: Routes.settings, desktopOnly: false),
  (label: 'Code', location: Routes.codeSettingsPath, desktopOnly: true),
  (label: 'Agents', location: Routes.agents, desktopOnly: true),
  (label: 'MCP servers', location: Routes.mcpServers, desktopOnly: true),
  (label: 'Skills', location: Routes.skills, desktopOnly: true),
  (label: 'Custom commands', location: Routes.commands, desktopOnly: false),
  (label: 'Memory', location: Routes.memory, desktopOnly: false),
  (label: 'Remote coding', location: Routes.remote, desktopOnly: false),
  (label: 'Plan & usage', location: Routes.billing, desktopOnly: false),
  (label: 'Usage', location: Routes.usage, desktopOnly: false),
  (label: 'Third-party notices', location: Routes.notices, desktopOnly: false),
];

/// Wraps every settings page. Wide: a section list beside the page, topped by
/// a way back to where Settings was opened from. Narrow: the page alone, with
/// a back control in its header (to the section list, or out of Settings).
class SettingsShell extends ConsumerWidget {
  const SettingsShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final path = Uri.parse(location).path;
    final origin = ref.watch(settingsReturnProvider);
    final atRoot = path == Routes.settings;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 760;
        final back = wide
            ? (origin == null ? null : () => context.go(origin))
            : atRoot
            ? (origin == null ? null : () => context.go(origin))
            : () => context.go(Routes.settings);
        final page = PageBackScope(
          onBack: wide ? null : back,
          tooltip: !wide && !atRoot ? 'All settings' : 'Back',
          child: child,
        );
        if (!wide) return page;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 220,
              decoration: BoxDecoration(
                color: theme.surface,
                border: Border(right: BorderSide(color: theme.border)),
              ),
              child: SafeArea(
                right: false,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
                  children: [
                    if (origin != null)
                      PopoverRow(
                        title: _originLabel(origin),
                        leading: AdaptiveIcon(EveryIcon.chevronLeft, size: 14, color: theme.textMuted),
                        onTap: () => context.go(origin),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                      child: Text('Settings', style: theme.type.headline.tint(theme.text)),
                    ),
                    for (final s in settingsSections)
                      if (!s.desktopOnly || Host.isDesktop)
                        PopoverRow(title: s.label, selected: path == s.location, onTap: () => context.go(s.location)),
                  ],
                ),
              ),
            ),
            Expanded(child: page),
          ],
        );
      },
    );
  }

  static String _originLabel(String origin) {
    final path = Uri.parse(origin).path;
    if (path.startsWith('/code')) return 'Back to Code';
    if (path.startsWith('/chat')) return 'Back to chat';
    return 'Back';
  }
}
