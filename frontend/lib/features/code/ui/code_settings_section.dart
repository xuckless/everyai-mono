import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../resume/resume_providers.dart' show resumeUnsupportedProvider;
import '../../../core/theme/every_theme.dart';
import '../../../core/platform/platform_kind.dart' show Host;
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../../core/ui/segmented.dart';
import '../../../core/ui/selection.dart';
import '../../../core/format/money.dart';
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../../settings/settings_registry.dart';
import '../../settings/ui/settings_modal.dart';
import '../../settings/ui/settings_sections.dart' show settingsPicker;
import '../code_providers.dart';
import '../forks/orphan_forks.dart';
import '../code_settings_providers.dart';
import '../domain/agent_mode.dart';
import '../domain/code_session.dart';
import '../drivers/detection/install_commands.dart';
import '../drivers/driver.dart' show DriverInfo, DriverStatus;
import '../drivers/driver_registry.dart';
import '../live/real_input.dart';
import '../drivers/registry_install/ui/add_agent_list.dart' show AddAgentEntry;
import '../permissions_providers.dart';
import '../settings/setting_defs.dart';
import '../settings/settings.dart' as files;
import '../migration/ui/bring_over_sheet.dart';
import 'code_slash_host.dart' show switchCodeAgent;
import '../../onboarding/domain/harness_rows.dart';
import '../../onboarding/git_bash_stub.dart';
import '../../onboarding/onboarding_harness_providers.dart';
import 'harness_setup_row.dart';
import 'research_sites_editor.dart' show researchSiteProblem, siteOf;

/// Settings → Code: the layers a session's settings come from (Global, a
/// project, a session), each as rows of typed controls. Rows a layer doesn't
/// set show what it inherits; "+ Add setting" sets one here. Values live in
/// `settings.json` files (Global: App Support; Project: `.everyai/`) or in
/// the app's Preferences, per setting (see [settingDefs]).
class CodeSettingsSection extends ConsumerStatefulWidget {
  const CodeSettingsSection({super.key, this.projectId, this.sessionId, this.scope});

  final String? projectId;
  final String? sessionId;
  final SettingsScope? scope;

  @override
  ConsumerState<CodeSettingsSection> createState() => _CodeSettingsSectionState();
}

class _CodeSettingsSectionState extends ConsumerState<CodeSettingsSection> {
  late String? _projectId =
      widget.projectId ?? (widget.sessionId == null ? null : _projectOfSession(widget.sessionId!));
  late String? _sessionId = widget.sessionId;
  late SettingsScope _scope = widget.scope ?? (widget.sessionId != null ? SettingsScope.session : SettingsScope.global);

  /// Project layer: write `settings.local.json` (just me) instead of the committed file.
  bool _local = false;

  /// Settings added with "+ Add setting" that still hold their default.
  final _added = <String>{};

  bool _json = false;
  bool _effective = false;

  @override
  void initState() {
    super.initState();
    _reveal(ref.read(settingsTargetProvider));
  }

  /// A search jump to a setting this layer doesn't set yet: show its row, so
  /// the jump has somewhere to land.
  void _reveal(SettingsTarget? t) {
    final key = t?.anchor;
    if (t == null || t.section != SettingsSection.code || key == null) return;
    final d = settingDefs.where((d) => d.key == key && d.addable).firstOrNull;
    if (d == null) return;
    if (!d.scopes.contains(_scope)) _scope = d.scopes.first;
    _added.add(key);
  }

  String? _projectOfSession(String id) =>
      ref.read(codeSessionsProvider).where((s) => s.id == id).firstOrNull?.projectId;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    ref.listen(settingsTargetProvider, (_, next) => setState(() => _reveal(next)));
    final projects = ref.watch(codeProjectsProvider);
    final project = projects.where((p) => p.id == _projectId).firstOrNull ?? projects.firstOrNull;
    final sessions = [
      for (final s in ref.watch(codeSessionsProvider))
        if (project == null || s.projectId == project.id) s,
    ];
    final session = sessions.where((s) => s.id == _sessionId).firstOrNull;
    bool can(SettingsScope s) => switch (s) {
      SettingsScope.global => true,
      SettingsScope.project => project != null,
      SettingsScope.session => sessions.isNotEmpty,
    };
    final scope = can(_scope) ? _scope : SettingsScope.global;

    final globalPath = ref.watch(userSettingsPathProvider).value;
    final projectPath = project == null ? null : files.projectLayerPath(project.path, local: _local);
    final layerPath = switch (scope) {
      SettingsScope.global => globalPath,
      SettingsScope.project => projectPath,
      SettingsScope.session => null,
    };
    final globalRaw = _raw(globalPath);
    final layerRaw = scope == SettingsScope.project ? _raw(projectPath) : globalRaw;
    final layerError = layerPath == null ? null : ref.watch(settingsLayerProvider(layerPath)).error;
    final layer = _Layer(
      scope: scope,
      projectId: scope == SettingsScope.global ? null : project?.id,
      path: layerPath,
      raw: layerRaw,
      below: scope == SettingsScope.project ? globalRaw : const {},
      prefs: ref.watch(codeSettingsProvider),
    );

    final defs = defsFor(scope);
    final shown = [
      for (final d in defs)
        if (_shows(d, layer) || (scope == SettingsScope.session && d.key != 'budget') || _added.contains(d.key)) d,
    ];
    final addable = [
      for (final d in defs)
        if (d.addable && !shown.contains(d)) d,
    ];

    return KitGroupedList(
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            AdaptiveSegmented<SettingsScope>(
              key: const ValueKey('code-settings.scope'),
              values: SettingsScope.values,
              selected: scope,
              label: (s) => s.label,
              enabled: can,
              onSelected: (s) => setState(() {
                _scope = s;
                _added.clear();
                if (s == SettingsScope.session && session == null) _sessionId = sessions.firstOrNull?.id;
              }),
            ),
            if (scope != SettingsScope.global && projects.isNotEmpty)
              AdaptiveMenuButton(
                actions: [
                  for (final p in projects)
                    MenuAction(
                      label: p.name,
                      checked: p.id == project?.id,
                      onSelected: () => setState(() {
                        _projectId = p.id;
                        _sessionId = null;
                        _added.clear();
                      }),
                    ),
                ],
                child: MenuTrigger(project?.name ?? 'Choose a project'),
              ),
            if (scope == SettingsScope.session && sessions.isNotEmpty)
              AdaptiveMenuButton(
                actions: [
                  for (final s in sessions.take(30))
                    MenuAction(
                      label: s.title.isEmpty ? 'Untitled session' : s.title,
                      checked: s.id == session?.id,
                      onSelected: () => setState(() => _sessionId = s.id),
                    ),
                ],
                child: MenuTrigger(
                  session == null ? 'Choose a session' : (session.title.isEmpty ? 'Untitled session' : session.title),
                ),
              ),
            if (scope == SettingsScope.project)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AdaptiveSwitch(
                    key: const ValueKey('code-settings.local'),
                    value: _local,
                    onChanged: (v) => setState(() => _local = v),
                  ),
                  const SizedBox(width: 6),
                  Text('Just me', style: theme.type.callout.tint(theme.text)),
                ],
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
          child: Text(switch (scope) {
            SettingsScope.global => 'Every project. Saved in ${globalPath ?? 'the app'} and the app.',
            SettingsScope.project =>
              'On top of Global for ${project?.name}. Saved in ${files.projectLayerPath('.', local: _local).substring(2)}'
                  '${_local ? ' (not committed)' : ' (committed with the repository)'}.',
            SettingsScope.session => 'This session only. Changes apply at once.',
          }, style: theme.type.caption.tint(theme.textMuted)),
        ),
        if (layerError != null)
          Padding(
            padding: const EdgeInsets.all(4),
            child: Text(
              '$layerPath isn\'t valid JSON, so it can\'t be edited here: $layerError',
              style: theme.type.callout.tint(theme.danger),
            ),
          ),
        if (scope == SettingsScope.session && session == null)
          Padding(
            padding: const EdgeInsets.all(4),
            child: Text('No session to show.', style: theme.type.callout.tint(theme.textMuted)),
          )
        else
          for (final d in shown)
            SettingsAnchor(section: SettingsSection.code, id: d.key, child: _row(context, d, layer, session, project)),
        if (addable.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: AdaptiveMenuButton(
                key: const ValueKey('code-settings.add'),
                width: 300,
                actions: [
                  for (final d in addable)
                    MenuAction(label: d.title, onSelected: () => setState(() => _added.add(d.key))),
                ],
                child: const MenuTrigger('+ Add setting'),
              ),
            ),
          ),
        if (scope == SettingsScope.global && Host.isDesktop) ...[
          const AdaptiveSectionHeader('Driving apps'),
          SettingsAnchor(
            section: SettingsSection.code,
            id: 'real-input',
            child: AdaptiveListTile(
              title: const Text('Use the real mouse and keyboard'),
              subtitle: const Text("For apps that can't be driven in the background"),
              trailing: AdaptiveSwitch(
                key: const ValueKey('code-settings.real-input'),
                value: RealInput.consent == RealInputConsent.allowed,
                onChanged: (v) => setState(() => RealInput.set(v)),
              ),
            ),
          ),
        ],
        if (scope == SettingsScope.global && Host.isDesktop) const _OrphanForks(),
        const SizedBox(height: 16),
        SettingsAnchor(section: SettingsSection.code, id: 'json', child: _jsonView(theme, layer, session, project?.id)),
        if (project != null) _FullPrompt(projectDir: project.path, projectId: project.id),
      ],
    );
  }

  Map<String, Object?> _raw(String? path) =>
      path == null ? const {} : ref.watch(settingsLayerProvider(path)).value ?? const {};

  /// Whether [d] gets a row without being added: it is set in this layer, or
  /// below it (shown as inherited), or always shows.
  bool _shows(SettingDef d, _Layer l) => switch (d.store) {
    SettingStore.none => true,
    SettingStore.session => true,
    _ when d.kind == SettingKind.permissions || d.kind == SettingKind.prompt => true,
    SettingStore.file => isSetInFile(d, l.raw) || isSetInFile(d, l.below),
    SettingStore.prefs =>
      isSetInPrefs(d, l.prefs, l.projectId) || (l.scope == SettingsScope.project && isSetInPrefs(d, l.prefs, null)),
  };

  Future<void> _writeFile(_Layer l, Map<String, Object?> Function(Map<String, Object?>) edit) async {
    final path = l.path;
    if (path == null) {
      showAdaptiveToast(context, 'Settings files are not available here.');
      return;
    }
    // Read before the write: "Just me" may flip, or the section close, while it runs.
    final project = _local && l.scope == SettingsScope.project
        ? ref.read(codeProjectsProvider).where((p) => p.id == l.projectId).firstOrNull
        : null;
    try {
      await files.writeLayer(path, edit);
      // A personal file never lands in git, even if the section closed meanwhile.
      if (project != null) await files.excludeFromGit(project.path, const ['/${files.localSettingsPath}']);
      if (mounted) ref.read(settingsFilesRevisionProvider.notifier).bump();
    } on Object catch (e) {
      if (mounted) showAdaptiveToast(context, "Couldn't save: $e");
    }
    if (mounted) ref.invalidate(settingsLayerProvider(path));
  }

  void _writePrefs(StoredCodeSettings next) => ref.read(codeSettingsProvider.notifier).replace(next);

  Future<void> _set(SettingDef d, _Layer l, Object? value) async {
    switch (d.store) {
      case SettingStore.file:
        await _writeFile(l, (raw) => writeFileValue(d, raw, value));
      case SettingStore.prefs:
        _writePrefs(writePrefsValue(d, ref.read(codeSettingsProvider), l.projectId, value));
      case SettingStore.session || SettingStore.none:
        break;
    }
  }

  Future<void> _clear(SettingDef d, _Layer l) async {
    setState(() => _added.remove(d.key));
    switch (d.store) {
      case SettingStore.file:
        await _writeFile(l, (raw) => clearFileValue(d, raw));
      case SettingStore.prefs:
        _writePrefs(clearPrefsValue(d, ref.read(codeSettingsProvider), l.projectId));
      case SettingStore.session || SettingStore.none:
        break;
    }
  }

  Widget _row(BuildContext context, SettingDef d, _Layer l, CodeSessionInfo? session, CodeProject? project) {
    final theme = EveryTheme.of(context);
    final set = switch (d.store) {
      SettingStore.file => isSetInFile(d, l.raw),
      SettingStore.prefs => isSetInPrefs(d, l.prefs, l.projectId),
      _ => true,
    };
    final belowSet = switch (d.store) {
      SettingStore.file => l.scope == SettingsScope.project && isSetInFile(d, l.below),
      SettingStore.prefs => l.scope == SettingsScope.project && isSetInPrefs(d, l.prefs, null),
      _ => false,
    };
    final inherited = !set && !_added.contains(d.key) && belowSet;
    final value = switch (d.store) {
      SettingStore.file => readFileValue(d, inherited ? l.below : l.raw) ?? d.fallback,
      SettingStore.prefs => readPrefsValue(d, l.prefs, inherited ? null : l.projectId),
      _ => null,
    };
    final removable = set && (d.store == SettingStore.file || d.store == SettingStore.prefs);

    Widget control;
    var block = false;
    switch (d.kind) {
      case SettingKind.toggle:
        control = AdaptiveSwitch(value: value == true, onChanged: (v) => _set(d, l, v));
      case SettingKind.choice when d.store == SettingStore.session:
        control = _sessionChoice(d, session!);
      case SettingKind.choice:
        control = settingsPicker<Object>(d.labelOf(value), d.choices, (v) => _set(d, l, v));
      case SettingKind.chips:
        block = true;
        final items = [...?value as List<String>?];
        final sites = d.key == 'researchSites';
        control = KitListEditor(
          key: ValueKey('code-settings.list.${d.key}.${l.scope.name}'),
          items: items,
          itemLabel: sites ? 'Site' : 'Rule',
          kindLabel: sites ? 'Covers' : null,
          kindOf: sites ? (s) => s.startsWith('*.') ? 'Site and subdomains' : 'This site' : null,
          placeholder: sites ? 'docs.python.org or *.example.com' : 'Run dart format -l 120 on changed files',
          empty: sites ? 'Empty: the defaults apply' : 'No rules',
          validate: sites ? researchSiteProblem : null,
          onChanged: (next) => _set(d, l, sites ? [for (final s in next) siteOf(s)] : next),
          onReset: sites && d.fallback is List<String> ? () => _set(d, l, d.fallback) : null,
        );
      case SettingKind.prompt:
        block = true;
        control = _PromptEditor(
          key: ValueKey('code-settings.prompt.${l.scope.name}.${l.projectId}'),
          text: readPrefsValue(d, l.prefs, l.projectId)! as String,
          below: l.scope == SettingsScope.project ? l.prefs.globalPrompt : '',
          onSave: (t) {
            _set(d, l, t);
            showAdaptiveToast(context, 'Saved. New sessions get it.');
          },
        );
      case SettingKind.money:
        final budget = ref.watch(codeSettingsProvider.select((s) => s.budgets[session?.id]));
        control = settingsPicker<double?>(budget == null ? 'No cap' : formatMicros((budget * 1e6).round()), [
          ('No cap', null),
          for (final usd in budgetPresets) (formatMicros((usd * 1e6).round()), usd),
        ], (v) => ref.read(codeSettingsProvider.notifier).setBudget(session!.id, v));
      case SettingKind.permissions:
        block = true;
        control = PermissionsEditor(
          scope: l.scope,
          projectId: l.projectId,
          raw: l.raw,
          onWrite: (edit) => _writeFile(l, edit),
        );
      case SettingKind.harnesses:
        block = true;
        control = const HarnessesSetting();
      case SettingKind.migration:
        control = AdaptiveButton(
          key: const ValueKey('code-settings.bring-over'),
          label: 'Choose what to bring over',
          emphasis: ButtonEmphasis.secondary,
          onPressed: () => showBringOver(context),
        );
      case SettingKind.link:
        control = AdaptiveButton(
          label: 'Open',
          emphasis: ButtonEmphasis.secondary,
          onPressed: () => showSettings(
            context,
            section: d.key == 'mcp' ? SettingsSection.mcp : SettingsSection.skills,
            args: {if (l.projectId != null) 'project': l.projectId!},
          ),
        );
    }

    final menu = removable
        ? AdaptiveMenuButton(
            key: ValueKey('code-settings.more.${d.key}'),
            actions: [
              MenuAction(
                label: d.store == SettingStore.prefs ? 'Reset to default' : 'Remove from this layer',
                icon: EveryIcon.retry,
                onSelected: () => _clear(d, l),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: AdaptiveIcon(EveryIcon.more, size: 14, color: theme.textMuted),
            ),
          )
        : const SizedBox(width: 26);
    final caption = inherited ? 'Inherited from Global. Change it to set it for this project.' : d.help;
    final head = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(d.title, style: theme.type.body.medium.tint(inherited ? theme.textMuted : theme.text)),
              const SizedBox(height: 2),
              Text(caption, style: theme.type.caption.tint(theme.textMuted)),
            ],
          ),
        ),
        if (!block) ...[const SizedBox(width: 12), Opacity(opacity: inherited ? 0.6 : 1, child: control)],
        menu,
      ],
    );
    return Container(
      key: ValueKey('code-settings.row.${d.key}'),
      // Each setting on its own quiet card: space separates them, not rules.
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.surfaceRaised.withValues(alpha: theme.isDark ? 0.55 : 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.border),
      ),
      child: block
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                head,
                const SizedBox(height: 8),
                Opacity(opacity: inherited ? 0.6 : 1, child: control),
              ],
            )
          : head,
    );
  }

  Widget _sessionChoice(SettingDef d, CodeSessionInfo session) {
    switch (d.key) {
      case 'mode':
        return settingsPicker<AgentMode>(session.mode.label, [
          for (final m in AgentMode.values) (m.label, m),
        ], (m) => ref.read(codeSessionProvider(session.id).notifier).setMode(m));
      case 'effort':
        return settingsPicker<Object>(
          d.labelOf(session.effort),
          d.choices,
          (e) => switchCodeAgent(context, ref, session.id, effort: e as String),
        );
      default:
        final catalog = ref.watch(modelCatalogProvider);
        final library = ref.watch(libraryProvider).value ?? const [];
        final current = catalog.resolve(ModelId(session.model));
        return settingsPicker<String>(current.name, [
          for (final m in {current, ...library})
            if (!m.isAuto) (m.name, m.id.value),
        ], (id) => switchCodeAgent(context, ref, session.id, model: id));
    }
  }

  Widget _jsonView(EveryTheme theme, _Layer l, CodeSessionInfo? session, String? projectId) {
    final sources = codeSettingsSources(
      ref,
      watch: true,
      session: session == null
          ? null
          : (
              model: session.model,
              effort: session.effort,
              mode: session.mode,
              budgetUsd: ref.watch(codeSettingsProvider).budgets[session.id],
            ),
    );
    final text = !_json
        ? ''
        : _effective
        ? prettyJson(effectiveJson(sources, projectId: projectId))
        : prettyJson({
            if (l.path != null) l.path!: l.raw,
            'kept in the app': layerJson(l.scope, sources, projectId: l.projectId),
          });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            AdaptiveButton(
              key: const ValueKey('code-settings.json'),
              label: _json ? 'Hide JSON' : 'View as JSON',
              emphasis: ButtonEmphasis.plain,
              icon: AdaptiveIcon(_json ? EveryIcon.chevronDown : EveryIcon.chevronRight, size: 12),
              onPressed: () => setState(() => _json = !_json),
            ),
            const Spacer(),
            if (_json) ...[
              AdaptiveSegmented<bool>(
                values: const [false, true],
                selected: _effective,
                label: (e) => e ? 'Effective' : 'This layer',
                onSelected: (e) => setState(() => _effective = e),
              ),
              AdaptiveIconButton(
                icon: EveryIcon.copy,
                tooltip: 'Copy',
                size: 14,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: text));
                  showAdaptiveToast(context, 'Copied');
                },
              ),
            ],
          ],
        ),
        if (_json)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.codeBackground,
              border: Border.all(color: theme.border),
              borderRadius: BorderRadius.circular(theme.radius),
            ),
            child: AdaptiveSelectionArea(child: Text(text, style: theme.type.caption.mono.tint(theme.text))),
          ),
      ],
    );
  }
}

/// What one layer of the editor reads and writes.
final class _Layer {
  const _Layer({
    required this.scope,
    required this.projectId,
    required this.path,
    required this.raw,
    required this.below,
    required this.prefs,
  });

  final SettingsScope scope;

  /// Null for Global.
  final String? projectId;

  /// The layer file (null for Session, or without an app folder).
  final String? path;
  final Map<String, Object?> raw;

  /// The Global file, under a project layer.
  final Map<String, Object?> below;
  final StoredCodeSettings prefs;
}

/// The install line shown for a missing CLI: the vendor's line for this system, else the driver's own hint (an agent
/// added by hand).
String? _installLine(DriverInfo info) {
  final os = SetupOs.of(defaultTargetPlatform);
  return (os == null ? null : setupCommandsFor(info.id, os)?.install) ?? info.installHint;
}

/// Settings → Code → Harnesses: each driver with what was found on this
/// computer, the consent switch for subscription CLIs, and Refresh.
class HarnessesSetting extends ConsumerWidget {
  const HarnessesSetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final statuses = ref.watch(driverStatusesProvider);
    final own = ref.watch(codeSettingsProvider.select((s) => s.ownClis));
    final drivers = ref.watch(driverRegistryProvider).listed.toList();
    final consent = [
      for (final d in drivers)
        if (d.info.needsConsent) d.info.label,
    ];
    final rows = harnessRows(
      drivers,
      ref.watch(harnessEnvStatusesProvider),
      hideAbsent: false,
      // The button offers Set up for a missing CLI here, so the dot says the same.
      appFound: (_) => true,
      builtInBlocked: ref.watch(gitBashMissingProvider),
    );
    final handoff = ref.watch(codeLeadProvider.select((l) => l.handoff));
    final resumeUnsupported = ref.watch(resumeUnsupportedProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GitForWindowsNotice(),
        for (final r in rows)
          KeyedSubtree(
            key: ValueKey('code-settings.harness.${r.id}${r.keySuffix}'),
            child: HarnessSetupRow(
              row: r,
              statusLine: statuses.hasError
                  ? "Couldn't check"
                  : r.id == everyaiHarnessName && r.state == RowState.setUp
                  ? 'Needs Git for Windows to run commands'
                  : null,
              footer: [
                if (r.status case DriverStatus(installed: false) when _installLine(r.driver.info) != null)
                  AdaptiveSelectionArea(
                    child: Text(
                      'To install: ${_installLine(r.driver.info)}',
                      key: ValueKey('code-settings.harness.${r.id}${r.keySuffix}.hint'),
                      style: theme.type.caption.mono.tint(theme.textMuted),
                    ),
                  ),
                // A harness whose earlier sessions can't be listed or loaded isn't offered on New session.
                if (resumeUnsupported(r.id) case final why?)
                  Text(
                    'Earlier sessions: not available for ${r.driver.info.label}${why.isEmpty ? '' : ' ($why)'}',
                    key: ValueKey('code-settings.harness.${r.id}${r.keySuffix}.resume'),
                    style: theme.type.caption.tint(theme.textMuted),
                  ),
              ],
              trailing: [
                if (r.driver.info.needsConsent && r.env.isHost) ...[
                  const SizedBox(width: 8),
                  Text('Use my own installed CLI', style: theme.type.caption.tint(theme.textMuted)),
                  const SizedBox(width: 8),
                  AdaptiveSwitch(
                    key: ValueKey('code-settings.own-cli.${r.id}'),
                    value: own.contains(r.driver.info.consentId),
                    onChanged: (v) => ref.read(codeSettingsProvider.notifier).setOwnCli(r.driver.info.consentId, v),
                  ),
                ],
              ],
            ),
          ),
        if (consent.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '${consent.join(' and ')} run the copy installed on this computer, signed in to your own account, so '
            'what they do counts against your plan with that company. They stay off until you turn them on.',
            style: theme.type.caption.tint(theme.textMuted),
          ),
        ],
        // Where a usage limit moves on to by itself (picked on the "switch to:" card).
        if (handoff.isNotEmpty)
          Padding(
            key: const ValueKey('code-settings.handoff-default'),
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Default handoff: ${ref.read(driverRegistryProvider).resolve(handoff)?.info.label ?? handoff}',
                    style: theme.type.callout.tint(theme.text),
                  ),
                ),
                AdaptiveButton(
                  key: const ValueKey('code-settings.handoff-default.clear'),
                  label: 'Clear',
                  emphasis: ButtonEmphasis.secondary,
                  onPressed: ref.read(codeLeadProvider.notifier).clearHandoff,
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            AdaptiveButton(
              key: const ValueKey('code-settings.harnesses.refresh'),
              label: 'Refresh',
              emphasis: ButtonEmphasis.secondary,
              onPressed: () {
                unawaited(ref.read(driverStatusesProvider.notifier).refresh(reloadShell: true));
                ref.invalidate(driverModelsProvider);
                ref.invalidate(gitBashMissingProvider);
              },
            ),
            if (ref.read(driverStatusesProvider.notifier).checkedAt case final at?) ...[
              const SizedBox(width: 10),
              Text(checkedAgo(DateTime.now().difference(at)), style: theme.type.caption.tint(theme.textMuted)),
            ],
          ],
        ),
        const SizedBox(height: 8),
        const AddAgentEntry(),
      ],
    );
  }
}

/// When the harnesses were last checked, in plain words.
String checkedAgo(Duration ago) => switch (ago.inMinutes) {
  < 1 => 'Checked just now',
  1 => 'Checked 1 min ago',
  < 60 => 'Checked ${ago.inMinutes} min ago',
  _ => ago.inHours == 1 ? 'Checked 1 hour ago' : 'Checked ${ago.inHours} hours ago',
};

/// One driver's status in plain words: the version or "Not installed",
/// whether it is signed in (when known) and what is in the way.
String harnessStatusLine(String id, DriverStatus s) => [
  if (id == everyaiHarnessName) 'Built in' else if (s.installed) s.version ?? 'Installed' else 'Not installed',
  if (s.signedIn case final signed?) signed ? 'signed in' : 'not signed in',
  if (s.problem case final p? when p.isNotEmpty) p.endsWith('.') ? p.substring(0, p.length - 1) : p,
].join(' · ');

/// A wrap of removable chips and an add chip.
/// One chip: a rule or a value, with ✕; or the "+ Add" chip.
class RuleChip extends StatelessWidget {
  const RuleChip({
    super.key,
    required this.label,
    this.onRemove,
    this.onTap,
    this.add = false,
    this.muted = false,
    this.note,
  });

  final String label;
  final VoidCallback? onRemove;
  final VoidCallback? onTap;
  final bool add;

  /// Shown dimmed (a rule that doesn't apply).
  final bool muted;

  /// A short note after the label ("in the app", "ignored").
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final fg = add ? theme.accent : (muted ? theme.textMuted : theme.text);
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: Container(
          padding: EdgeInsets.fromLTRB(10, 4, onRemove == null ? 10 : 4, 4),
          decoration: BoxDecoration(
            color: add ? null : theme.surfaceRaised,
            border: Border.all(color: add ? theme.accent.withValues(alpha: 0.5) : theme.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: (add ? theme.type.callout.medium : theme.type.callout.mono).tint(fg),
                ),
              ),
              if (note != null) ...[
                const SizedBox(width: 6),
                Text(note!, style: theme.type.caption.tint(theme.textMuted)),
              ],
              if (onRemove != null)
                AdaptiveIconButton(
                  icon: EveryIcon.close,
                  tooltip: 'Remove $label',
                  size: 11,
                  color: theme.textMuted,
                  onPressed: onRemove,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A text area with Save and Revert, for one layer's system prompt.
class _PromptEditor extends StatefulWidget {
  const _PromptEditor({super.key, required this.text, required this.below, required this.onSave});

  final String text;

  /// The Global prompt, shown under a project's (they join).
  final String below;
  final ValueChanged<String> onSave;

  @override
  State<_PromptEditor> createState() => _PromptEditorState();
}

class _PromptEditorState extends State<_PromptEditor> {
  late final _controller = TextEditingController(text: widget.text);

  @override
  void didUpdateWidget(_PromptEditor old) {
    super.didUpdateWidget(old);
    // Changed elsewhere while untouched here: follow it.
    if (old.text != widget.text && _controller.text == old.text) _controller.text = widget.text;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final dirty = _controller.text.trim() != widget.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.below.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Global adds: ${widget.below.length > 120 ? '${widget.below.substring(0, 120)}…' : widget.below}',
              style: theme.type.caption.tint(theme.textMuted),
            ),
          ),
        AdaptiveTextField(
          key: const ValueKey('code-settings.prompt'),
          controller: _controller,
          minLines: 4,
          maxLines: 14,
          keyboardType: TextInputType.multiline,
          placeholder: 'e.g. Answer in British English. Prefer small PRs.',
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AdaptiveButton(
              key: const ValueKey('code-settings.prompt.save'),
              label: 'Save',
              onPressed: dirty ? () => widget.onSave(_controller.text) : null,
            ),
            AdaptiveButton(
              label: 'Revert',
              emphasis: ButtonEmphasis.secondary,
              onPressed: dirty ? () => setState(() => _controller.text = widget.text) : null,
            ),
          ],
        ),
      ],
    );
  }
}

/// "See full prompt": what EveryAI adds to the agent's system prompt for a
/// new session in the project, read-only.
class _FullPrompt extends ConsumerStatefulWidget {
  const _FullPrompt({required this.projectDir, required this.projectId});

  final String projectDir;
  final String projectId;

  @override
  ConsumerState<_FullPrompt> createState() => _FullPromptState();
}

class _FullPromptState extends ConsumerState<_FullPrompt> {
  Future<String>? _text;

  Future<String> _load() async {
    final s = ref.read(codeSettingsProvider);
    final p = await files.agentPromptFor(widget.projectDir, tier: s.tier);
    final suffix = withSystemPrompts(p.suffix, global: s.globalPrompt, project: s.promptFor(widget.projectId));
    return '${p.persona}\n\n$suffix'.trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final open = _text != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: AdaptiveButton(
            key: const ValueKey('code-settings.full-prompt'),
            label: open ? 'Hide full prompt' : 'See full prompt',
            emphasis: ButtonEmphasis.plain,
            icon: AdaptiveIcon(open ? EveryIcon.chevronDown : EveryIcon.chevronRight, size: 12),
            onPressed: () => setState(() => _text = open ? null : _load()),
          ),
        ),
        if (_text case final future?)
          FutureBuilder<String>(
            future: future,
            builder: (context, snap) => Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.codeBackground,
                border: Border.all(color: theme.border),
                borderRadius: BorderRadius.circular(theme.radius),
              ),
              child: switch (snap) {
                AsyncSnapshot(:final data?) => AdaptiveSelectionArea(
                  child: Text(data, style: theme.type.caption.mono.tint(theme.text)),
                ),
                AsyncSnapshot(:final error?) => Text(
                  "Couldn't build the prompt: $error",
                  style: theme.type.caption.tint(theme.danger),
                ),
                _ => const AdaptiveProgress(),
              },
            ),
          ),
      ],
    );
  }
}

/// Allow and deny rules for one layer, as chips, with "+ Add rule".
///
/// - Global: rules go into the user's `settings.json`; rules saved from
///   approval cards ("Always allow", kept in the app) show too.
/// - Project: deny rules go into the project file. A project file can't
///   allow (anyone who can commit could approve commands for you), so allow
///   rules go into the app's store for the project; any in the file show as
///   ignored.
class PermissionsEditor extends ConsumerWidget {
  const PermissionsEditor({
    super.key,
    required this.scope,
    required this.projectId,
    required this.raw,
    required this.onWrite,
  });

  final SettingsScope scope;
  final String? projectId;

  /// The layer file's JSON.
  final Map<String, Object?> raw;
  final Future<void> Function(Map<String, Object?> Function(Map<String, Object?>) edit) onWrite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final stored = ref.watch(codePermissionsProvider);
    final app = scope == SettingsScope.global ? stored.global : stored.projects[projectId] ?? PermissionRules.none;
    final file = fileRules(raw);
    final project = scope == SettingsScope.project;
    final store = ref.read(codePermissionsProvider.notifier);

    Future<void> add() async {
      final rule = await showRuleBuilder(context);
      if (rule == null) return;
      if (project && rule.allow) {
        store.allow(rule.text, projectId: projectId);
      } else {
        await onWrite((r) => addFileRule(r, rule.text, allow: rule.allow));
      }
    }

    Widget list(String title, {required bool allow}) {
      final inApp = allow ? app.allow : app.deny;
      final inFile = allow ? file.allow : file.deny;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.type.caption.semibold.tint(theme.textMuted)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in inFile)
                  RuleChip(
                    key: ValueKey('rule.file.$r'),
                    label: r,
                    muted: project && allow,
                    note: project && allow ? 'ignored' : null,
                    onRemove: () => onWrite((raw) => removeFileRule(raw, r)),
                  ),
                for (final r in inApp)
                  RuleChip(
                    key: ValueKey('rule.app.$r'),
                    label: r,
                    note: 'in the app',
                    onRemove: () => store.remove(r, projectId: scope == SettingsScope.global ? null : projectId),
                  ),
                if (inFile.isEmpty && inApp.isEmpty) Text('None', style: theme.type.callout.tint(theme.textMuted)),
              ],
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        list('Allow', allow: true),
        list('Deny', allow: false),
        if (project)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Allow rules in the project\'s settings files are ignored: anyone who can commit could approve '
              'commands for you. Allow rules you add here are kept in the app for this project; deny rules go '
              'into the file.',
              style: theme.type.caption.tint(theme.warning),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: RuleChip(key: const ValueKey('rule.add'), label: '+ Add rule', add: true, onTap: add),
        ),
      ],
    );
  }
}

/// The "+ Add rule" steps: what it matches, the pattern, allow or deny.
/// Returns the rule in `PermissionRules` syntax, or null when cancelled.
Future<({String text, bool allow})?> showRuleBuilder(BuildContext context) =>
    showKitDialog(context, builder: (_) => const _RuleBuilder());

class _RuleBuilder extends StatefulWidget {
  const _RuleBuilder();

  @override
  State<_RuleBuilder> createState() => _RuleBuilderState();
}

class _RuleBuilderState extends State<_RuleBuilder> {
  RuleTool? _tool;
  final _pattern = TextEditingController();

  @override
  void dispose() {
    _pattern.dispose();
    super.dispose();
  }

  void _finish(bool allow) {
    final text = ruleFor(_tool!, _pattern.text);
    if (text != null) Navigator.of(context).pop((text: text, allow: allow));
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final tool = _tool;
    final preview = tool == null ? null : ruleFor(tool, _pattern.text);
    return Center(
      child: SizedBox(
        width: 420,
        child: GlassSurface(
          level: GlassLevel.thick,
          radius: EveryTheme.cardRadius,
          padding: const EdgeInsets.all(18),
          child: DefaultTextStyle(
            style: theme.type.body.tint(theme.text),
            child: CallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop()},
              child: FocusScope(
                autofocus: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      tool == null ? '1. What should the rule match?' : '2. ${tool.label}: which ones?',
                      style: theme.type.headline.tint(theme.text),
                    ),
                    const SizedBox(height: 10),
                    if (tool == null)
                      for (final t in RuleTool.values)
                        PopoverRow(
                          key: ValueKey('rule-builder.${t.name}'),
                          title: t.label,
                          subtitle: t.hint,
                          onTap: () => setState(() => _tool = t),
                        )
                    else ...[
                      Text(tool.hint, style: theme.type.caption.tint(theme.textMuted)),
                      const SizedBox(height: 8),
                      AdaptiveTextField(
                        key: const ValueKey('rule-builder.pattern'),
                        controller: _pattern,
                        autofocus: true,
                        placeholder: switch (tool) {
                          RuleTool.command => 'npm test *',
                          RuleTool.edit => 'src/**',
                          RuleTool.read => '.env*',
                          RuleTool.mcp => 'browser_*',
                        },
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        preview == null ? '3. Then allow or deny it.' : 'Rule: $preview',
                        style: theme.type.caption.mono.tint(theme.textMuted),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          AdaptiveButton(
                            label: 'Back',
                            emphasis: ButtonEmphasis.plain,
                            onPressed: () => setState(() => _tool = null),
                          ),
                          const Spacer(),
                          AdaptiveButton(
                            key: const ValueKey('rule-builder.deny'),
                            label: 'Deny',
                            emphasis: ButtonEmphasis.destructive,
                            onPressed: preview == null ? null : () => _finish(false),
                          ),
                          const SizedBox(width: 8),
                          AdaptiveButton(
                            key: const ValueKey('rule-builder.allow'),
                            label: 'Allow',
                            onPressed: preview == null ? null : () => _finish(true),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Settings → Permissions: the Global rules and each project's, with the
/// same editor as the Code section's Permissions row.
class PermissionsSection extends ConsumerWidget {
  const PermissionsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final projects = ref.watch(codeProjectsProvider);
    final globalPath = ref.watch(userSettingsPathProvider).value;

    Widget block(String title, String? path, SettingsScope scope, String? projectId, String? dir) {
      final raw = path == null ? const <String, Object?>{} : ref.watch(settingsLayerProvider(path)).value ?? const {};
      return Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AdaptiveSectionHeader(title),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: PermissionsEditor(
                scope: scope,
                projectId: projectId,
                raw: raw,
                onWrite: (edit) async {
                  if (path == null) return;
                  try {
                    await files.writeLayer(path, edit);
                    ref.read(settingsFilesRevisionProvider.notifier).bump();
                  } on Object catch (e) {
                    if (context.mounted) showAdaptiveToast(context, "Couldn't save: $e");
                  }
                  ref.invalidate(settingsLayerProvider(path));
                },
              ),
            ),
          ],
        ),
      );
    }

    return KitGroupedList(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'A rule is a command glob (npm test *) or a path rule: Edit(src/**), Read(.env*), Mcp(browser_*). Deny '
            'wins over allow, and a short list of destructive commands is always blocked.',
            style: theme.type.caption.tint(theme.textMuted),
          ),
        ),
        block('Global', globalPath, SettingsScope.global, null, null),
        for (final p in projects) block(p.name, files.projectLayerPath(p.path), SettingsScope.project, p.id, p.path),
      ],
    );
  }
}

/// Fork worktrees with work of their own that no session holds any more (see [orphanForksProvider]); nothing shows
/// when there are none.
class _OrphanForks extends ConsumerWidget {
  const _OrphanForks();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orphans = ref.watch(orphanForksProvider).value ?? const [];
    if (orphans.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AdaptiveSectionHeader('Left-over forks'),
        for (final o in orphans)
          AdaptiveListTile(
            title: Text(o.path.split('/').last),
            subtitle: Text(
              o.repoRoot.isEmpty
                  ? 'Its repository is gone. ${o.path}'
                  : "Unsaved work from a fork of ${o.repoRoot.split('/').last} whose session is gone. ${o.path}",
            ),
            trailing: AdaptiveButton(
              label: 'Remove',
              emphasis: ButtonEmphasis.destructive,
              onPressed: () async {
                final ok = await showAdaptiveConfirm(
                  context,
                  title: 'Remove this fork?',
                  message: 'Its worktree at ${o.path} and the changes in it are deleted.',
                  confirmLabel: 'Remove',
                );
                if (ok) await ref.read(orphanForksProvider.notifier).remove(o);
              },
            ),
          ),
      ],
    );
  }
}
