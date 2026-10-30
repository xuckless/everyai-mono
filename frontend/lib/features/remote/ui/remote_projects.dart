import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../data/remote_store.dart';
import '../domain/remote_protocol.dart';
import '../remote_providers.dart';

/// The projects a paired host offers (its Code projects), fetched through the relay.
final remoteProjectsProvider = FutureProvider.autoDispose.family<List<({String name, String path})>, String>((
  ref,
  hostId,
) async {
  final client = await ref.read(remoteLinksProvider).client(hostId);
  return client.projects();
});

/// Rows for Code's project picker: each approved host's projects, to add
/// as `remote://` projects. [onAdd] gets the stored path and a display name.
class RemoteProjectRows extends ConsumerWidget {
  const RemoteProjectRows({super.key, required this.onAdd, this.added = const {}});

  final void Function(String path, String name) onAdd;

  /// Paths already in the project list (not offered again).
  final Set<String> added;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final hosts = (ref.watch(pairedHostsProvider).value ?? const <PairedHost>[]).where((h) => h.approved);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final h in hosts) ...[
          PopoverHeader('On ${h.name.isEmpty ? 'your computer' : h.name}'),
          ...switch (ref.watch(remoteProjectsProvider(h.hostId))) {
            AsyncData(:final value) when value.isEmpty => [
              const PopoverRow(title: 'No projects', subtitle: 'Open a folder in Code on that computer first'),
            ],
            AsyncData(:final value) => [
              for (final p in value)
                if (!added.contains(remotePath(h.hostId, p.path)))
                  PopoverRow(
                    leading: AdaptiveIcon(EveryIcon.add, size: 15, color: theme.textMuted),
                    title: p.name,
                    subtitle: p.path,
                    onTap: () => onAdd(remotePath(h.hostId, p.path), '${p.name} (${h.name})'),
                  ),
            ],
            AsyncError(:final error) => [
              PopoverRow(
                title: "Couldn't reach it",
                subtitle: '$error',
                onTap: () => ref.invalidate(remoteProjectsProvider(h.hostId)),
              ),
            ],
            _ => [const PopoverRow(title: 'Loading projects…')],
          },
        ],
      ],
    );
  }
}
