// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../../core/ui/layout.dart';
import '../../code/drivers/detection/install_commands.dart';
import '../../settings/settings_registry.dart';
import '../../settings/ui/settings_modal.dart';
import '../data/server_probe.dart' show testServer;
import '../domain/local_server.dart' show normaliseBaseUrl;
import '../local_model_bridge.dart' show localModelStatesProvider, ModelLoad;
import '../local_models_providers.dart';
import 'local_setup_terminal.dart';

/// Preferences → Local models: what this computer can run, the starter packs, the servers found here (Apple's model
/// among them), the models they serve, and servers added by URL.
class LocalModelsSection extends ConsumerWidget {
  const LocalModelsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final servers = ref.watch(localServersProvider);
    final models = ref.watch(localModelsProvider).value ?? const <LocalModel>[];
    final fm = ref.watch(fmStatusProvider).value;
    return KitGroupedList(
      children: [
        const SpecLine(),
        const AdaptiveSectionHeader('Starter packs'),
        const SettingsAnchor(section: SettingsSection.localModels, id: 'packs', child: LocalPacksPicker()),
        const AdaptiveSectionHeader('On this computer'),
        if (fm != null && fm.state != FmState.missing)
          SettingsAnchor(
            section: SettingsSection.localModels,
            id: 'fm',
            child: FmRow(status: fm),
          ),
        if (servers.isLoading && !servers.hasValue)
          AdaptiveListTile(title: Text('Looking for servers…', style: theme.type.body.tint(theme.textMuted))),
        for (final s in servers.value ?? const <LocalServer>[])
          if (s.kind != LocalServerKind.fm || fm == null) _ServerRow(server: s),
        if (servers.hasValue && servers.value!.isEmpty && (fm == null || fm.state == FmState.missing))
          AdaptiveListTile(
            key: const ValueKey('local.none'),
            title: const Text('No model servers found'),
            subtitle: const Text('Download a pack above, or start Ollama or LM Studio'),
          ),
        SettingsAnchor(
          section: SettingsSection.localModels,
          id: 'add-server',
          child: AdaptiveListTile(
            key: const ValueKey('local.add-server'),
            leading: const AdaptiveIcon(EveryIcon.add, size: 16),
            title: const Text('Add a server'),
            subtitle: const Text('Any OpenAI-compatible server, by URL'),
            onTap: () => showAddServerDialog(context),
          ),
        ),
        const AdaptiveSectionHeader('Models'),
        for (final m in models) _ModelRow(model: m),
        if (models.isEmpty)
          AdaptiveListTile(title: Text('No local models yet', style: theme.type.body.tint(theme.textMuted))),
      ],
    );
  }
}

/// "This Mac: M2 Pro · 16 GB unified · 212 GB free", with Refresh.
class SpecLine extends ConsumerWidget {
  const SpecLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final spec = ref.watch(hardwareSpecProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: WrapRow(
        lead: Text(
          spec.value?.summary ?? (spec.hasError ? "Couldn't read this computer's hardware" : 'Reading this computer…'),
          key: const ValueKey('local.spec'),
          style: theme.type.callout.tint(theme.textMuted),
        ),
        actions: [
          AdaptiveButton(
            key: const ValueKey('local.refresh'),
            label: 'Refresh',
            emphasis: ButtonEmphasis.plain,
            onPressed: () {
              ref.invalidate(hardwareSpecProvider);
              ref.read(localServersProvider.notifier).refresh();
            },
          ),
        ],
      ),
    );
  }
}

/// The three packs against this computer (greyed when they don't fit, the best fit picked), and one Download
/// button. Downloads go through Ollama; when it's missing the button sets it up first.
class LocalPacksPicker extends ConsumerStatefulWidget {
  const LocalPacksPicker({super.key});

  @override
  ConsumerState<LocalPacksPicker> createState() => _LocalPacksPickerState();
}

class _LocalPacksPickerState extends ConsumerState<LocalPacksPicker> {
  String? _picked;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final fits = ref.watch(packsProvider);
    final downloads = ref.watch(downloadsProvider);
    final servers = ref.watch(localServersProvider).value ?? const <LocalServer>[];
    final ollama = servers.where((s) => s.kind == LocalServerKind.ollama).firstOrNull;
    final list = fits.value ?? const <PackFit>[];
    final picked =
        list.where((f) => f.pack.id == _picked && f.fits).firstOrNull ??
        list.where((f) => f.best).firstOrNull ??
        list.where((f) => f.fits).firstOrNull;
    return KitCard(
      key: const ValueKey('local.packs'),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (fits.isLoading && !fits.hasValue)
            Text('Checking what fits…', style: theme.type.callout.tint(theme.textMuted)),
          if (fits.hasError) Text("Couldn't load the packs", style: theme.type.callout.tint(theme.danger)),
          for (final f in list)
            _PackRow(
              fit: f,
              selected: f.pack.id == picked?.pack.id,
              onTap: f.fits ? () => setState(() => _picked = f.pack.id) : null,
            ),
          if (picked != null) ...[
            const SizedBox(height: 10),
            for (final tag in picked.pack.tags)
              if (downloads[tag] case final d?) _DownloadLine(state: d),
            const SizedBox(height: 4),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: _PackAction(pack: picked.pack, ollama: ollama, downloads: downloads),
            ),
          ],
        ],
      ),
    );
  }
}

class _PackRow extends StatelessWidget {
  const _PackRow({required this.fit, required this.selected, required this.onTap});

  final PackFit fit;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final pack = fit.pack;
    final muted = !fit.fits;
    final size = pack.sizeGb < 10 ? pack.sizeGb.toStringAsFixed(1) : pack.sizeGb.round().toString();
    return MenuRow(
      key: ValueKey('local.pack.${pack.id}'),
      selected: selected,
      onTap: onTap,
      leading: _Radio(on: selected, enabled: fit.fits),
      // Wide: label, size and blurb on one line, like the owner's sketch. Narrow: the blurb goes below.
      child: LayoutBuilder(
        builder: (context, box) {
          final label = Text(
            pack.label,
            style: theme.type.body.medium.tint(muted ? theme.textMuted : theme.text),
            overflow: TextOverflow.ellipsis,
          );
          final gbText = Text('~$size GB', style: theme.type.callout.mono.tint(theme.textMuted));
          final blurb = Text(
            muted ? fit.reason ?? pack.blurb : pack.blurb,
            style: theme.type.callout.tint(theme.textMuted),
            overflow: TextOverflow.ellipsis,
            maxLines: box.maxWidth < 420 ? 2 : 1,
          );
          final best = fit.best ? Text('Fits best', style: theme.type.caption.tint(theme.accent)) : null;
          if (box.maxWidth < 420) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(child: label),
                    const SizedBox(width: 8),
                    gbText,
                    if (best != null) ...[const SizedBox(width: 8), Flexible(child: best)],
                  ],
                ),
                blurb,
              ],
            );
          }
          return Row(
            children: [
              SizedBox(width: 84, child: label),
              SizedBox(width: 64, child: gbText),
              Expanded(child: blurb),
              if (best != null) Padding(padding: const EdgeInsetsDirectional.only(start: 8), child: best),
            ],
          );
        },
      ),
    );
  }
}

class _Radio extends StatelessWidget {
  const _Radio({required this.on, required this.enabled});
  final bool on;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final color = !enabled
        ? theme.border
        : on
        ? theme.accent
        : theme.textMuted;
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 1.5),
      ),
      alignment: Alignment.center,
      child: on
          ? Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            )
          : null,
    );
  }
}

/// Download, or what has to happen first: set up Ollama, start it.
class _PackAction extends ConsumerWidget {
  const _PackAction({required this.pack, required this.ollama, required this.downloads});

  final Pack pack;
  final LocalServer? ollama;
  final Map<String, DownloadState> downloads;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = (ref.watch(localModelsProvider).value ?? const <LocalModel>[])
        .where((m) => m.serverId == 'ollama')
        .map((m) => m.name)
        .toSet();
    final missing = [
      for (final t in pack.tags)
        if (!installed.contains(t) && !installed.contains('$t:latest')) t,
    ];
    final busy = pack.tags.any((t) => downloads[t]?.active ?? false);
    if (ollama == null) {
      return AdaptiveButton(
        key: const ValueKey('local.setup-ollama'),
        label: 'Set up Ollama to download',
        onPressed: () => openOllamaSetup(context, ref),
      );
    }
    if (!ollama!.running) {
      return AdaptiveButton(
        key: const ValueKey('local.start-ollama'),
        label: 'Start Ollama',
        onPressed: () => startServer(context, ref, ollama!),
      );
    }
    if (missing.isEmpty) {
      return AdaptiveButton(
        key: const ValueKey('local.pack.ready'),
        label: '${pack.label} is ready',
        emphasis: ButtonEmphasis.plain,
        onPressed: null,
      );
    }
    if (busy) {
      return AdaptiveButton(
        key: const ValueKey('local.pack.cancel'),
        label: 'Cancel',
        emphasis: ButtonEmphasis.secondary,
        onPressed: () {
          for (final t in pack.tags) {
            ref.read(downloadsProvider.notifier).cancel(t);
          }
        },
      );
    }
    return AdaptiveButton(
      key: const ValueKey('local.pack.download'),
      label: 'Download ${pack.label}',
      icon: const AdaptiveIcon(EveryIcon.download, size: 14),
      onPressed: () => ref.read(downloadsProvider.notifier).enqueue(missing),
    );
  }
}

/// Opens our terminal with Ollama's official install line for this system typed in.
Future<void> openOllamaSetup(BuildContext context, WidgetRef ref) async {
  final os = SetupOs.of(defaultTargetPlatform);
  final commands = os == null ? null : setupCommandsFor('ollama', os);
  if (commands == null) {
    showAdaptiveToast(context, 'Install Ollama from ollama.com/download, then refresh.');
    return;
  }
  await showLocalSetupTerminal(
    context,
    title: 'Set up Ollama',
    line: commands.install,
    explanation: "Ollama's own install line, typed below. Press Enter to run it; type your password if asked.",
    source: commands.source,
    onCheck: () => ref.read(localServersProvider.notifier).refresh(),
  );
}

/// Opens our terminal with `sudo fm license` typed in, for the user to read and agree to Apple's terms.
Future<void> openFmLicence(BuildContext context, WidgetRef ref) => showLocalSetupTerminal(
  context,
  title: 'Set up Apple Intelligence',
  line: fmLicenceCommand,
  explanation: "Apple's terms, agreed once per Mac. Press Enter, type your password, then read and agree.",
  onCheck: () => ref.read(localServersProvider.notifier).refresh(),
);

class _DownloadLine extends StatelessWidget {
  const _DownloadLine({required this.state});
  final DownloadState state;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final s = state;
    final words = switch (s.phase) {
      DownloadPhase.queued => 'Waiting',
      DownloadPhase.running =>
        s.total != null && s.done != null ? '${_size(s.done!)} of ${_size(s.total!)}' : (s.status ?? 'Starting'),
      DownloadPhase.done => 'Ready',
      DownloadPhase.failed => s.error ?? 'Failed',
      DownloadPhase.cancelled => 'Stopped. Download again to carry on.',
    };
    return Padding(
      key: ValueKey('local.download.${s.tag}'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(s.tag, style: theme.type.caption.mono.tint(theme.text))),
              Text(
                words,
                style: theme.type.caption.tint(s.phase == DownloadPhase.failed ? theme.danger : theme.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 3),
          ThinProgress(value: s.phase == DownloadPhase.done ? 1 : s.fraction),
        ],
      ),
    );
  }

  static String _size(int bytes) =>
      bytes >= 1 << 30 ? '${(bytes / (1 << 30)).toStringAsFixed(1)} GB' : '${(bytes / (1 << 20)).round()} MB';
}

/// A 3pt bar; null [value] is an empty track.
class ThinProgress extends StatelessWidget {
  const ThinProgress({super.key, this.value});
  final double? value;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 3,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: theme.border),
            FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: (value ?? 0).clamp(0.0, 1.0),
              child: ColoredBox(color: theme.accent),
            ),
          ],
        ),
      ),
    );
  }
}

/// Apple's on-device model: Set up (agree to the terms), Ready, or not on this Mac.
class FmRow extends ConsumerWidget {
  const FmRow({super.key, required this.status});
  final FmStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(localServersProvider).value ?? const <LocalServer>[];
    final server = servers.where((s) => s.kind == LocalServerKind.fm).firstOrNull;
    final phase = server == null ? null : ref.watch(serverLifecyclesProvider.notifier).phaseOf(server);
    ref.watch(serverLifecyclesProvider);
    final (dot, line) = switch (status.state) {
      FmState.ready when phase is ServerRunning => (DotStatus.done, 'Ready · free and private, on this Mac'),
      FmState.ready when phase != null => (_dotOf(phase), _phaseLine(phase)),
      FmState.ready => (DotStatus.waiting, 'Starting…'),
      FmState.needsLicence => (DotStatus.idle, "Agree to Apple's terms once to use it"),
      FmState.unsupported => (DotStatus.failed, "This Mac can't run Apple Intelligence"),
      FmState.missing => (DotStatus.idle, 'Not on this Mac'),
    };
    return AdaptiveListTile(
      key: const ValueKey('local.fm'),
      leading: StatusDot(dot),
      title: const Text('Apple Intelligence'),
      subtitle: Text(line),
      trailing: status.state == FmState.needsLicence
          ? AdaptiveButton(
              key: const ValueKey('local.fm.setup'),
              label: 'Set up',
              onPressed: () => openFmLicence(context, ref),
            )
          : status.state == FmState.ready && server != null
          ? ServerControls(server: server)
          : null,
    );
  }
}

DotStatus _dotOf(ServerPhase p) => switch (p) {
  ServerRunning() => DotStatus.done,
  ServerStarting() || ServerStopping() => DotStatus.running,
  ServerFailed() || ServerNotClosed() => DotStatus.failed,
  ServerStopped() => DotStatus.idle,
};

String _phaseLine(ServerPhase p) => switch (p) {
  ServerRunning(owner: ServerOwner.everyai) => 'Running · started by EveryAI',
  ServerRunning(owner: ServerOwner.outside) => 'Running · started outside EveryAI',
  ServerStarting() => 'Starting…',
  ServerStopping() => 'Stopping…',
  ServerFailed(:final reason) => reason,
  ServerNotClosed(:final reason) => 'Not closed · $reason',
  ServerStopped() => 'Stopped',
};

/// Starts [server], saying why when it can't.
Future<void> startServer(BuildContext context, WidgetRef ref, LocalServer server) async {
  final problem = await ref.read(serverLifecyclesProvider.notifier).start(server);
  if (problem != null && context.mounted) showAdaptiveToast(context, "Couldn't start ${server.label}: $problem");
}

/// Stops [server]; one EveryAI didn't start is stopped only after the user confirms.
Future<void> stopServer(BuildContext context, WidgetRef ref, LocalServer server) async {
  final lifecycles = ref.read(serverLifecyclesProvider.notifier);
  if (lifecycles.phaseOf(server) case ServerRunning(owner: ServerOwner.outside)) {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Stop ${server.label}?',
      message: 'It was started outside EveryAI. Apps using it lose it too.',
      confirmLabel: 'Stop',
      destructive: true,
    );
    if (!ok) return;
  }
  final problem = await lifecycles.stop(server);
  if (problem != null && context.mounted) showAdaptiveToast(context, "Couldn't stop ${server.label}: $problem");
}

/// Start or Stop for a server, by its phase: off (busy) while either runs.
class ServerControls extends ConsumerWidget {
  const ServerControls({super.key, required this.server});
  final LocalServer server;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(serverLifecyclesProvider);
    final phase = ref.read(serverLifecyclesProvider.notifier).phaseOf(server);
    return switch (phase) {
      ServerRunning() || ServerStopping() || ServerNotClosed() => AdaptiveButton(
        key: ValueKey('local.server.${server.id}.stop'),
        label: phase is ServerNotClosed ? 'Stop again' : 'Stop',
        emphasis: ButtonEmphasis.secondary,
        busy: phase is ServerStopping,
        onPressed: phase is ServerStopping ? null : () => stopServer(context, ref, server),
      ),
      ServerStopped() || ServerFailed() || ServerStarting() when ServerLifecycles.canStart(server) => AdaptiveButton(
        key: ValueKey('local.server.${server.id}.start'),
        label: phase is ServerFailed ? 'Try again' : 'Start',
        emphasis: ButtonEmphasis.secondary,
        busy: phase is ServerStarting,
        onPressed: phase is ServerStarting ? null : () => startServer(context, ref, server),
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

class _ServerRow extends ConsumerWidget {
  const _ServerRow({required this.server});
  final LocalServer server;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = server;
    ref.watch(serverLifecyclesProvider);
    final phase = ref.read(serverLifecyclesProvider.notifier).phaseOf(s);
    final where = Uri.parse(s.baseUrl).authority;
    return AdaptiveListTile(
      key: ValueKey('local.server.${s.id}'),
      leading: StatusDot(_dotOf(phase)),
      title: Text(s.label),
      subtitle: Text(
        phase is ServerStopped && s.problem != null ? '${s.problem} · $where' : '${_phaseLine(phase)} · $where',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ServerControls(server: s),
          if (s.manual) ...[
            const SizedBox(width: 6),
            AdaptiveIconButton(
              key: ValueKey('local.server.${s.id}.remove'),
              icon: EveryIcon.close,
              tooltip: 'Remove',
              size: 14,
              onPressed: phase.busy
                  ? null
                  : () async {
                      final problem = await ref.read(manualServersProvider.notifier).remove(s.id);
                      if (problem != null && context.mounted) {
                        showAdaptiveToast(context, "Couldn't remove ${s.label}: $problem");
                      }
                    },
            ),
          ],
        ],
      ),
    );
  }
}

class _ModelRow extends ConsumerWidget {
  const _ModelRow({required this.model});
  final LocalModel model;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = model;
    final servers = ref.watch(localServersProvider).value ?? const <LocalServer>[];
    final server = localServerById(servers, m.serverId);
    final abilities = [if (m.tools) 'tools', if (m.vision) 'pictures', if (m.reasoning) 'thinking'];
    final facts = [
      server?.label ?? m.serverId,
      if (m.sizeBytes case final b?) b >= 1 << 30 ? '${(b / (1 << 30)).toStringAsFixed(1)} GB' : '${b ~/ (1 << 20)} MB',
      if (m.contextTokens case final c?) '${m.contextGuessed ? '~' : ''}${c >= 1024 ? '${c ~/ 1024}K' : '$c'} context',
      if (abilities.isNotEmpty) abilities.join(', '),
    ];
    final deletable = server?.kind == LocalServerKind.ollama;
    final load = server == null
        ? null
        : ref.watch(localModelStatesProvider.select((s) => s.value?['${server.baseUrl}|${m.name}']));
    final controllable = server != null && server.running && _loadable(server.kind);
    final loadState = load?.state ?? ModelLoad.unloaded;
    final loadLine = switch (loadState) {
      _ when !controllable => null,
      ModelLoad.loaded => load!.ours ? 'Loaded by EveryAI' : 'Loaded',
      ModelLoad.loading => 'Loading…',
      ModelLoad.unloading => 'Unloading…',
      ModelLoad.failed => load?.reason ?? 'Failed',
      ModelLoad.unloaded => 'Not loaded',
    };
    return AdaptiveListTile(
      key: ValueKey('local.model.${m.id}'),
      title: Text(m.name),
      subtitle: Text([?loadLine, ...facts].join(' · ')),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (controllable)
            AdaptiveButton(
              key: ValueKey('local.model.${m.id}.${loadState == ModelLoad.loaded ? 'unload' : 'load'}'),
              label: loadState == ModelLoad.loaded || loadState == ModelLoad.unloading ? 'Unload' : 'Load',
              emphasis: ButtonEmphasis.secondary,
              busy: loadState.busy,
              onPressed: loadState.busy
                  ? null
                  : () async {
                      final states = ref.read(localModelStatesProvider.notifier);
                      final problem = loadState == ModelLoad.loaded
                          ? await states.unload(server, m.name)
                          : await states.load(server, m.name);
                      if (problem != null && context.mounted) showAdaptiveToast(context, problem);
                    },
            ),
          if (deletable) ...[
            const SizedBox(width: 6),
            AdaptiveIconButton(
              key: ValueKey('local.model.${m.id}.delete'),
              icon: EveryIcon.delete,
              tooltip: 'Delete from this computer',
              size: 14,
              onPressed: () async {
                final ok = await showAdaptiveConfirm(
                  context,
                  title: 'Delete ${m.name}?',
                  message: 'You can download it again later.',
                  confirmLabel: 'Delete',
                  destructive: true,
                );
                if (!ok) return;
                final problem = await ref.read(downloadsProvider.notifier).delete(m.name);
                if (problem != null && context.mounted) showAdaptiveToast(context, "Couldn't delete it: $problem");
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// The servers EveryAI can load and unload models on; the others keep their models loaded themselves.
bool _loadable(LocalServerKind k) => k == LocalServerKind.ollama || k == LocalServerKind.lmstudio;

/// Adds a server by URL: base URL, an optional name and key; Test asks it for its models first.
Future<void> showAddServerDialog(BuildContext context) =>
    showKitDialog<void>(context, builder: (ctx) => const _AddServerDialog());

class _AddServerDialog extends ConsumerStatefulWidget {
  const _AddServerDialog();

  @override
  ConsumerState<_AddServerDialog> createState() => _AddServerDialogState();
}

/// What the Add a server dialog last learnt about the URL in the field:
///
/// ```text
///  none ──Test──► testing(url) ──answer──► answered(url, n) | problem(msg)
///    ▲                 │
///    └── URL edited ───┘ (from any state; a test still under way is then dropped)
/// ```
sealed class _ServerTest {
  const _ServerTest();
}

final class _Testing extends _ServerTest {
  const _Testing(this.url);
  final String url;
}

final class _Answered extends _ServerTest {
  const _Answered(this.url, this.models);
  final String url;
  final int models;
}

final class _Problem extends _ServerTest {
  const _Problem(this.message);
  final String message;
}

class _AddServerDialogState extends ConsumerState<_AddServerDialog> {
  final _url = TextEditingController();
  final _label = TextEditingController();
  final _key = TextEditingController();
  final _command = TextEditingController();
  _ServerTest? _check;
  var _adding = false;
  late String _lastUrl;

  @override
  void initState() {
    super.initState();
    _lastUrl = _url.text;
    _url.addListener(_urlChanged);
  }

  void _urlChanged() {
    if (_url.text == _lastUrl) return;
    _lastUrl = _url.text;
    // A result belongs to the URL it was for.
    if (_check != null) setState(() => _check = null);
  }

  @override
  void dispose() {
    _url.dispose();
    _label.dispose();
    _key.dispose();
    _command.dispose();
    super.dispose();
  }

  LocalServer? get _draft {
    final url = normaliseBaseUrl(_url.text);
    if (url == null) return null;
    return LocalServer(
      id: 'draft',
      kind: LocalServerKind.custom,
      label: _label.text,
      baseUrl: url,
      apiKey: _key.text.trim(),
    );
  }

  Future<void> _test() async {
    if (_check is _Testing) return;
    final draft = _draft;
    if (draft == null) {
      setState(() => _check = const _Problem('Enter an http or https URL'));
      return;
    }
    final testing = _Testing(draft.baseUrl);
    setState(() => _check = testing);
    final r = await testServer(ref.read(localHttpProvider), draft);
    // Edited or closed meanwhile: this answer is for another URL.
    if (!mounted || !identical(_check, testing)) return;
    setState(() => _check = r.problem == null ? _Answered(draft.baseUrl, r.models.length) : _Problem(r.problem!));
  }

  Future<void> _add() async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      final added = await ref
          .read(manualServersProvider.notifier)
          .add(baseUrl: _url.text, label: _label.text, apiKey: _key.text, startCommand: _command.text);
      if (!mounted) return;
      if (added == null) {
        setState(() => _check = const _Problem('Enter an http or https URL'));
        return;
      }
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return KitDialog(
      title: 'Add a server',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('On this computer or your network'),
          const SizedBox(height: 10),
          AdaptiveTextField(
            key: const ValueKey('local.add.url'),
            controller: _url,
            placeholder: 'http://127.0.0.1:8080/v1',
            autofocus: true,
          ),
          const SizedBox(height: 8),
          AdaptiveTextField(key: const ValueKey('local.add.label'), controller: _label, placeholder: 'Name (optional)'),
          const SizedBox(height: 8),
          AdaptiveTextField(
            key: const ValueKey('local.add.key'),
            controller: _key,
            placeholder: 'API key (optional)',
            obscureText: true,
          ),
          const SizedBox(height: 8),
          AdaptiveTextField(
            key: const ValueKey('local.add.command'),
            controller: _command,
            placeholder: 'Start command (optional), e.g. llama-server -m model.gguf --port 8080',
          ),
          if (switch (_check) {
                _Answered(:final models) => ('It answered with $models model${models == 1 ? '' : 's'}', theme.success),
                _Problem(:final message) => (message, theme.danger),
                _Testing() || null => null,
              }
              case (final text, final colour)) ...[
            const SizedBox(height: 8),
            Text(text, key: const ValueKey('local.add.result'), style: theme.type.caption.tint(colour)),
          ],
        ],
      ),
      actions: [
        AdaptiveButton(label: 'Cancel', emphasis: ButtonEmphasis.plain, onPressed: () => Navigator.of(context).pop()),
        AdaptiveButton(
          key: const ValueKey('local.add.test'),
          label: 'Test',
          emphasis: ButtonEmphasis.secondary,
          busy: _check is _Testing,
          onPressed: _check is _Testing ? null : _test,
        ),
        AdaptiveButton(
          key: const ValueKey('local.add.save'),
          label: 'Add',
          busy: _adding,
          onPressed: _adding ? null : _add,
        ),
      ],
    );
  }
}

/// A card with what this computer can run and the packs, for onboarding, the model picker and Chat's empty state.
class LocalSetupCard extends ConsumerWidget {
  const LocalSetupCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fm = ref.watch(fmStatusProvider).value;
    return Column(
      key: const ValueKey('local.setup-card'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SpecLine(),
        if (fm != null && fm.state != FmState.missing && fm.state != FmState.unsupported) ...[
          KitGroup(children: [FmRow(status: fm)]),
          const SizedBox(height: 10),
        ],
        const LocalPacksPicker(),
      ],
    );
  }
}

/// Opens the local model setup (spec line, Apple's model, packs) as a dialog, with a link to Settings → Local models.
Future<void> showLocalModelSetup(BuildContext context) => showKitDialog<void>(
  context,
  builder: (ctx) => KitDialog(
    title: 'Run models on this computer',
    width: 560,
    body: const LocalSetupCard(),
    actions: [
      AdaptiveButton(
        label: 'More in Settings',
        emphasis: ButtonEmphasis.plain,
        onPressed: () {
          Navigator.of(ctx).pop();
          showSettings(context, section: SettingsSection.localModels);
        },
      ),
      AdaptiveButton(label: 'Done', onPressed: () => Navigator.of(ctx).pop()),
    ],
  ),
);
