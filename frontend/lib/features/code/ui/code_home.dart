import 'dart:math' show Random;

import '../../../core/preferences.dart';
import '../../../core/motion/motion.dart';

import 'package:file_selector/file_selector.dart' show getDirectoryPath;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/links/app_link.dart';
import '../../../core/links/link_providers.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../attachments/attachment.dart';
import '../../../core/platform/platform_kind.dart';
import '../agent_models.dart';
import '../code_providers.dart';
import '../../remote/host_mirror.dart' show remoteFollowedProvider;
import '../sample/sample_project.dart';
import '../domain/agent_mode.dart';
import '../domain/code_session.dart';
import '../../slash/slash_command.dart' show CodeSlashHost;
import '../morning_providers.dart';
import '../workflows/workflow_library.dart' show WorkflowOrigin;
import '../workflows/workflow_picker.dart';
import 'agent_menu.dart';
import 'code_composer.dart';
import 'transcript/aside_card.dart';
import 'session_view.dart';
import 'code_top_bar.dart' show SessionSettingsList;
import 'console/session_actions.dart';
import '../code_settings_providers.dart';
import '../drivers/driver_registry.dart' show driverRegistryProvider;
import '../environments/environment_picker.dart';
import '../harness/events.dart' show HarnessEvent;
import '../resume/past_sessions.dart';
import '../resume/resume_providers.dart';
import 'harness_logo.dart';
import 'panes/terminal_pane.dart' show TerminalTabsView;
import '../panes/panes_providers.dart' show homeTerminalOwner;
import '../panes/pty.dart' show shellSupported, terminalHomeDir;

/// The New session page's headline: one picked at random each time the page opens.
const startWords = [
  'What should we build?',
  "What's next?",
  'What needs fixing?',
  'Where do we start?',
  'Ship something.',
  'What are we making?',
  'Pick a task.',
  'Ready when you are.',
];

/// Where demo sessions "run" (the mock harness ignores the folder).
const demoProjectPath = '${demoScheme}counter-app';

/// Preferences key: whether Code home's terminal is open.
const _terminalKey = 'code.home.terminal';

/// Code landing: pick a project, describe the task, start a session.
class CodeHome extends ConsumerStatefulWidget {
  const CodeHome({super.key, this.projectId});

  /// The project to pick for the new session (a project's New session in the sidebar), else the last one shown.
  final String? projectId;

  @override
  ConsumerState<CodeHome> createState() => _CodeHomeState();
}

class _CodeHomeState extends ConsumerState<CodeHome> {
  final _headline = startWords[Random().nextInt(startWords.length)];
  late String? _projectId = widget.projectId;
  AgentMode? _picked;
  bool _isolated = false;

  /// The workflow picked for the new session, or null for none.
  WorkflowPick? _workflow;

  /// A spending cap for the new session (dollars), or null for none.
  double? _budget;
  bool _starting = false;

  /// A prompt from an everyai:// link, put in the box for the user to review.
  ({String text, int seq})? _prefill;

  @override
  void didUpdateWidget(CodeHome old) {
    super.didUpdateWidget(old);
    // New session from another project's menu while Code home is already showing.
    if (widget.projectId != null && widget.projectId != old.projectId) {
      setState(() {
        _projectId = widget.projectId;
        _picked = null;
      });
    }
  }

  /// Takes a pending link prompt: the project it names (else the one showing) and its text. Never starts a session.
  void _takeLinkPrompt() {
    final link = mounted ? ref.read(pendingPromptProvider.notifier).take() : null;
    if (link == null) return;
    final named = ref.read(codeProjectsProvider).where((p) => p.id == link.projectId).firstOrNull;
    setState(() {
      if (named != null) {
        _projectId = named.id;
        _picked = null;
      }
      _prefill = (text: link.text, seq: (_prefill?.seq ?? 0) + 1);
    });
    showAdaptiveToast(context, 'From a link. Review before you send.');
  }

  /// The earlier session being picked up (`harness|id`), while its history is read.
  String? _resuming;

  /// The mode last used in [projectId]; Auto-edit the first time.
  AgentMode _modeFor(String? projectId) {
    if (_picked case final m?) return m;
    final saved = projectId == null ? null : ref.read(preferencesProvider)[lastModeKey(projectId)];
    return AgentMode.values.asNameMap()[saved] ?? AgentMode.autoEdit;
  }

  void _pickMode(AgentMode mode, String? projectId) {
    setState(() => _picked = mode);
    if (projectId != null) ref.read(preferencesProvider)[lastModeKey(projectId)] = mode.name;
  }

  Future<CodeProject?> _openFolder() async {
    final path = await getDirectoryPath(confirmButtonText: 'Open');
    if (path == null) return null;
    final project = ref.read(codeProjectsProvider.notifier).add(path);
    setState(() => _projectId = project.id);
    return project;
  }

  Future<void> _addSample() async {
    try {
      final path = await createSampleProject();
      final project = ref.read(codeProjectsProvider.notifier).add(path, name: 'counter-app (sample)');
      setState(() => _projectId = project.id);
    } on Object catch (e) {
      if (mounted) showAdaptiveToast(context, 'Couldn\'t create the sample project: $e');
    }
  }

  /// A project on a paired host (remote mode).
  void _addDemo() {
    final project = ref.read(codeProjectsProvider.notifier).add(demoProjectPath, name: 'counter-app (demo)');
    setState(() => _projectId = project.id);
  }

  /// The lead the new session runs on: the pick, except that the scripted demo always runs its own.
  String _leadFor(CodeProject project) =>
      isDemoPath(project.path) ? everyaiHarnessName : ref.read(codeLeadProvider).harness;

  /// The model and effort for [harness]: an outside lead's own pick, else the EveryAI harness's.
  ({String model, String effort}) _modelFor(String harness) => harness == everyaiHarnessName
      ? (model: ref.read(codeAgentProvider).model, effort: ref.read(codeAgentProvider).effort)
      : ref.read(codeLeadProvider).of(harness);

  Future<void> _start(CodeProject project, String prompt, List<Attachment> files) async {
    final mode = _modeFor(project.id);
    ref.read(preferencesProvider)[lastModeKey(project.id)] = mode.name;
    final harness = _leadFor(project);
    final (:model, :effort) = _modelFor(harness);
    // The scripted demo runs no workflows.
    final workflow = isDemoPath(project.path) ? null : _workflow;
    setState(() => _starting = true);
    try {
      final info = await ref
          .read(codeSessionsProvider.notifier)
          .start(
            project: project,
            prompt: prompt,
            model: model,
            effort: effort,
            mode: mode,
            files: files,
            isolated: _isolated,
            tier: ref.read(codeSettingsProvider).tier,
            harness: harness,
            workflow: workflow,
          );
      if (_budget case final usd?) ref.read(codeSettingsProvider.notifier).setBudget(info.id, usd);
      if (mounted) setState(() => _workflow = null);
      if (mounted) context.go(Routes.codeSession(info.id));
    } on Object catch (e) {
      if (mounted) showAdaptiveToast(context, 'Couldn\'t start the session: $e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Picks up [past] on its own harness: its history is read from the harness's files, then the session opens.
  Future<void> _resume(CodeProject project, PastSession past) async {
    setState(() => _resuming = '${past.harness}|${past.nativeId}');
    try {
      final source = sourceOf(ref.read(pastSessionSourcesProvider), past);
      var history = const <HarnessEvent>[];
      try {
        history = await source?.history(past) ?? const [];
      } on Object {
        // The harness still has the whole conversation; only our copy of its earlier turns is missing.
      }
      final info = await ref
          .read(codeSessionsProvider.notifier)
          .resumePast(project: project, past: past, mode: _modeFor(project.id), history: history);
      if (mounted) context.go(Routes.codeSession(info.id));
    } on Object catch (e) {
      if (mounted) showAdaptiveToast(context, "Couldn't resume the session: $e");
    } finally {
      if (mounted) setState(() => _resuming = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final projects = ref.watch(codeProjectsProvider);
    final project = projects.where((p) => p.id == _projectId).firstOrNull ?? projects.firstOrNull;
    final mode = _modeFor(project?.id);
    final lead = project == null || isDemoPath(project.path) ? everyaiHarnessName : ref.watch(codeLeadProvider).harness;
    // The box only exists once there is a project; a link waits until then.
    if (project != null && ref.watch(pendingPromptProvider)?.mode == PromptTarget.code) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _takeLinkPrompt());
    }
    final earlier = project == null ? const <EarlierSession>[] : ref.watch(earlierSessionsProvider(project.id));

    final prefs = ref.read(preferencesProvider);
    final terminalOpen = shellSupported && prefs[_terminalKey] == 'open';
    return AdaptivePage(
      title: '',
      actions: [
        if (shellSupported)
          _TerminalButton(
            open: terminalOpen,
            onPressed: () => setState(() => prefs[_terminalKey] = terminalOpen ? null : 'open'),
          ),
      ],
      body: LayoutBuilder(
        builder: (context, box) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 24, 20, 48),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                project == null ? 'Open a project' : _headline,
                                textAlign: TextAlign.center,
                                style: theme.type.largeTitle.tint(theme.text),
                              ).settle(),
                              const SizedBox(height: 24),
                              if (project == null)
                                _NoProjects(onOpen: _openFolder, onSample: _addSample, onDemo: _addDemo)
                              else ...[
                                if (ref.watch(morningBriefProvider) case final brief?)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: AsideCard(
                                      key: ValueKey(brief.id),
                                      aside: brief,
                                      onDismiss: ref.read(morningBriefProvider.notifier).dismiss,
                                    ),
                                  ),
                                CodeComposer(
                                  prefill: _prefill,
                                  project: project.path,
                                  slashHost: CodeSlashHost(
                                    setMode: (name) => _pickMode(AgentMode.values.byName(name), project.id),
                                    morning: ref.read(morningBriefProvider.notifier).refresh,
                                  ),
                                  busy: _starting,
                                  mode: mode,
                                  minLines: 3,
                                  placeholder: 'Describe the task',
                                  onModeChanged: (m) => _pickMode(m, project.id),
                                  onSend: (text, files) => _start(project, text, files),
                                  agent: AgentMenu(
                                    harness: lead,
                                    onHarness: isDemoPath(project.path)
                                        ? null
                                        : ref.read(codeLeadProvider.notifier).chooseHarness,
                                    model: lead == everyaiHarnessName
                                        ? ref.watch(codeAgentProvider).model
                                        : ref.watch(codeLeadProvider).of(lead).model,
                                    effort: lead == everyaiHarnessName
                                        ? ref.watch(codeAgentProvider).effort
                                        : ref.watch(codeLeadProvider).of(lead).effort,
                                    demo: isDemoPath(project.path),
                                    onChanged: lead == everyaiHarnessName
                                        ? ref.read(codeAgentProvider.notifier).chooseModel
                                        : (model, effort) =>
                                              ref.read(codeLeadProvider.notifier).chooseModel(lead, model, effort),
                                    level: ref.watch(codeSettingsProvider.select((s) => s.tier)),
                                    onLevel: ref.read(codeSettingsProvider.notifier).setTier,
                                    workflow: _workflow,
                                    onWorkflow: (w) => setState(() => _workflow = w),
                                    projectDir: project.path,
                                    budget: _budget,
                                    onBudget: (v) => setState(() => _budget = v),
                                    environment: project.environment,
                                  ),
                                  leading: _ProjectPicker(
                                    project: project,
                                    projects: projects,
                                    onPick: (p) => setState(() {
                                      _projectId = p.id;
                                      _picked = null;
                                      // Another project's own workflows aren't this one's.
                                      if (_workflow?.entry?.origin == WorkflowOrigin.project) _workflow = null;
                                    }),
                                    onOpen: _openFolder,
                                    onSample: _addSample,
                                    onDemo: _addDemo,
                                  ),
                                  lineExtras: [
                                    if (!isDemoPath(project.path)) ...[
                                      _WorkspaceMenu(
                                        isolated: _isolated,
                                        onIsolated: (v) => setState(() => _isolated = v),
                                      ),
                                      if (Host.isDesktop)
                                        EnvironmentChip(
                                          quiet: true,
                                          envId: project.environment,
                                          onPick: (id) =>
                                              ref.read(codeProjectsProvider.notifier).setEnvironment(project.id, id),
                                        ),
                                      AnchoredPopover(
                                        width: 320,
                                        builder: (context, close) =>
                                            SessionSettingsList(projectId: project.id, close: close),
                                        child: Semantics(
                                          button: true,
                                          label: 'Session settings',
                                          child: const QuietTrigger(icon: EveryIcon.settings, chevron: false),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                if (_starting)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 14),
                                    child: Center(child: ShimmerText('Starting the agent', style: theme.type.callout)),
                                  ),
                                // This folder's earlier sessions: EveryAI's own (marked) and every installed harness's.
                                if (earlier.isNotEmpty) ...[
                                  const SizedBox(height: 36),
                                  const Padding(
                                    padding: EdgeInsets.only(left: 10, bottom: 4),
                                    child: KitLabel('Earlier'),
                                  ),
                                  for (final (i, row) in earlier.indexed)
                                    if (row.ours case final s?)
                                      SessionTile(
                                        key: ValueKey('code-home.earlier.${s.id}'),
                                        info: s,
                                        // The harness it ran on, by name beside its logo (like the earlier outside sessions).
                                        badge:
                                            ref.read(driverRegistryProvider).resolve(s.harness)?.info.label ??
                                            s.harness,
                                        onOpen: () => context.go(Routes.codeSession(s.id)),
                                      ).rowIn(i)
                                    else if (row.past case final p?)
                                      PastSessionTile(
                                        key: ValueKey('code-home.earlier.${p.harness}.${p.nativeId}'),
                                        past: p,
                                        label:
                                            ref.read(driverRegistryProvider).resolve(p.harness)?.info.label ??
                                            p.harness,
                                        blocked: row.blocked,
                                        busy: _resuming == '${p.harness}|${p.nativeId}',
                                        onOpen: _resuming != null || _starting ? null : () => _resume(project, p),
                                      ).rowIn(i),
                                ],
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (terminalOpen)
              _HomeTerminal(maxHeight: box.maxHeight * 0.75, onClose: () => setState(() => prefs[_terminalKey] = null)),
          ],
        ),
      ),
    );
  }
}

/// The prefs key for the mode last used in a project.
String lastModeKey(String projectId) => 'code.lastMode.$projectId';

/// Where the session works: in the project folder, or on its own branch in a worktree.
class _WorkspaceMenu extends StatelessWidget {
  const _WorkspaceMenu({required this.isolated, required this.onIsolated});

  final bool isolated;
  final ValueChanged<bool> onIsolated;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    Widget row(String title, String subtitle, bool value, VoidCallback close) => PopoverRow(
      key: ValueKey('code-home.workspace.${value ? 'worktree' : 'in-place'}'),
      title: title,
      subtitle: subtitle,
      selected: isolated == value,
      trailing: isolated == value ? AdaptiveIcon(EveryIcon.check, size: 14, color: theme.accentText) : null,
      onTap: () {
        close();
        onIsolated(value);
      },
    );
    return AnchoredPopover(
      width: 280,
      builder: (context, close) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row('In place', 'In the project folder, in your shell', false, close),
            row('Isolated worktree', 'Its own branch; merge or open a PR after', true, close),
          ],
        ),
      ),
      child: Semantics(
        button: true,
        label: 'Works: ${isolated ? 'isolated worktree' : 'in place'}',
        child: QuietTrigger(label: isolated ? 'Worktree' : 'In place', icon: isolated ? EveryIcon.branch : null),
      ),
    );
  }
}

class _NoProjects extends StatelessWidget {
  const _NoProjects({required this.onOpen, required this.onSample, required this.onDemo});
  final VoidCallback onOpen;
  final VoidCallback onSample;
  final VoidCallback onDemo;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        KitButton(label: 'Open folder…', icon: EveryIcon.projects, onPressed: onOpen),
        KitButton(label: 'Sample project', style: KitButtonStyle.soft, onPressed: onSample),
        KitButton(label: 'Scripted demo', style: KitButtonStyle.ghost, onPressed: onDemo),
      ],
    ).settle(delay: const Duration(milliseconds: 60));
  }
}

class _ProjectPicker extends StatelessWidget {
  const _ProjectPicker({
    required this.project,
    required this.projects,
    required this.onPick,
    required this.onOpen,
    required this.onSample,
    required this.onDemo,
  });

  final CodeProject project;
  final List<CodeProject> projects;
  final ValueChanged<CodeProject> onPick;
  final VoidCallback onOpen;
  final VoidCallback onSample;
  final VoidCallback onDemo;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return AnchoredPopover(
      width: 300,
      // Many projects with long paths outgrow the popover's height cap.
      builder: (context, close) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PopoverHeader('Projects'),
            // Live, so removing one updates the open list.
            Consumer(
              builder: (context, ref, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final p in ref.watch(codeProjectsProvider))
                    PopoverRow(
                      key: ValueKey('project.${p.id}'),
                      title: p.name,
                      trailing: AdaptiveIconButton(
                        icon: EveryIcon.close,
                        tooltip: 'Remove from the list (the folder stays)',
                        size: 12,
                        onPressed: () => ref.read(codeProjectsProvider.notifier).remove(p.id),
                      ),
                      subtitle: isDemoPath(p.path) ? 'Scripted demo' : p.path,
                      selected: p.id == project.id,
                      onTap: () {
                        close();
                        onPick(p);
                      },
                    ),
                ],
              ),
            ),
            if (Host.isDesktop) ...[
              PopoverRow(
                leading: AdaptiveIcon(EveryIcon.add, size: 15, color: theme.textMuted),
                title: 'Open folder…',
                onTap: () {
                  close();
                  onOpen();
                },
              ),
              PopoverRow(
                leading: AdaptiveIcon(EveryIcon.add, size: 15, color: theme.textMuted),
                title: 'New sample project',
                subtitle: 'A small Dart repo for the real agent',
                onTap: () {
                  close();
                  onSample();
                },
              ),
            ],
            if (!projects.any((p) => isDemoPath(p.path)))
              PopoverRow(
                leading: AdaptiveIcon(EveryIcon.add, size: 15, color: theme.textMuted),
                title: 'Scripted demo',
                onTap: () {
                  close();
                  onDemo();
                },
              ),
          ],
        ),
      ),
      child: Semantics(
        button: true,
        label: 'Project: ${project.name}',
        child: IgnorePointer(
          child: KitChip(
            label: project.name,
            leading: AdaptiveIcon(EveryIcon.projects, size: 14),
            chevron: true,
            onTap: () {},
          ),
        ),
      ),
    );
  }
}

/// The sidebar's mark for a session: its harness's logo, with its state as a dot on the corner (breathing while it
/// runs, amber when it needs you, red when it failed, none when it is idle or done, so Recents stay quiet).
class SessionStatusIcon extends StatelessWidget {
  const SessionStatusIcon({super.key, required this.status, required this.harness});

  final SessionStatus status;

  /// The harness id the session runs on.
  final String harness;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final (key, dot) = switch (status) {
      SessionStatus.running || SessionStatus.starting => ('status-running', DotStatus.running),
      SessionStatus.needsInput => ('status-needs-input', DotStatus.waiting),
      SessionStatus.failed => ('status-failed', DotStatus.failed),
      SessionStatus.idle || SessionStatus.done => (null, null),
    };
    return SizedBox.square(
      dimension: 18,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          HarnessLogo(harness, size: 18),
          if (dot != null)
            Positioned(
              right: -3,
              bottom: -3,
              child: DecoratedBox(
                key: ValueKey<String>(key!),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: theme.background, width: 2),
                ),
                child: StatusDot(dot, size: 7),
              ),
            ),
        ],
      ),
    );
  }
}

/// A session in a list: status dot, title, age.
class SessionTile extends ConsumerStatefulWidget {
  const SessionTile({
    super.key,
    required this.info,
    required this.onOpen,
    this.selected = false,
    this.dense = false,
    this.badge,
    this.caption,
  });

  final CodeSessionInfo info;

  /// Muted text under the title (the project, in a list that has no project headers).
  final String? caption;

  /// A small mark after the title ("EveryAI" in a list that mixes in other harnesses' sessions).
  final String? badge;
  final VoidCallback onOpen;
  final bool selected;
  final bool dense;

  @override
  ConsumerState<SessionTile> createState() => _SessionTileState();
}

class _SessionTileState extends ConsumerState<SessionTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    // Open sessions have a live status; the rest come from the harness.
    final status = ref.exists(codeSessionProvider(widget.info.id))
        ? ref.watch(codeSessionProvider(widget.info.id).select((s) => s.status))
        : ref.watch(codeStatusesProvider.select((all) => all[widget.info.id])) ?? SessionStatus.idle;
    final followed = ref.watch(remoteFollowedProvider.select((ids) => ids.contains(widget.info.id)));
    final pr = widget.info.prNumber;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onOpen,
        child: Semantics(
          button: true,
          selected: widget.selected,
          label:
              '${widget.info.title}, ${status.label}'
              '${pr == null ? '' : ', pull request $pr'}${followed ? ', followed from another device' : ''}',
          child: Container(
            margin: EdgeInsets.symmetric(horizontal: widget.dense ? 8 : 0, vertical: 1),
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: widget.dense ? 7 : 9),
            decoration: BoxDecoration(
              color: widget.selected
                  ? theme.text.withValues(alpha: 0.09)
                  : _hover
                  ? theme.text.withValues(alpha: 0.05)
                  : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                if (widget.dense)
                  SessionStatusIcon(status: status, harness: widget.info.harness)
                else
                  StatusPill(status: status, dense: true),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.info.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.type.callout.tint(theme.text),
                      ),
                      if (widget.caption case final c?)
                        Text(
                          c,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.type.caption.tint(theme.textMuted),
                        ),
                    ],
                  ),
                ),
                if (pr != null) ...[
                  Text(
                    '#$pr',
                    key: const ValueKey('session-pr'),
                    style: theme.type.caption.medium.tint(theme.textMuted),
                  ),
                  const SizedBox(width: 6),
                ],
                if (followed) ...[
                  AdaptiveIcon(
                    EveryIcon.devices,
                    key: const ValueKey('session-followed'),
                    size: 13,
                    color: theme.textMuted,
                  ),
                  const SizedBox(width: 6),
                ],
                if (widget.badge case final b?) ...[
                  HarnessLogo(widget.info.harness, size: 14, label: b),
                  const SizedBox(width: 5),
                  Text(b, style: theme.type.caption.tint(theme.textMuted)),
                  const SizedBox(width: 8),
                ],
                if (!widget.dense) Text(_age(widget.info.createdAt), style: theme.type.caption.tint(theme.textMuted)),
                Opacity(
                  opacity: _hover || widget.selected || Host.isMobile ? 1 : 0,
                  child: AdaptiveMenuButton(
                    tooltip: 'Session options',
                    actions: [
                      MenuAction(
                        label: widget.info.pinned ? 'Unpin' : 'Pin',
                        icon: EveryIcon.pin,
                        onSelected: () =>
                            ref.read(codeSessionsProvider.notifier).setPinned(widget.info.id, !widget.info.pinned),
                      ),
                      MenuAction(label: 'Rename', icon: EveryIcon.edit, onSelected: _rename),
                      MenuAction(label: 'Export transcript…', icon: EveryIcon.download, onSelected: _export),
                      MenuAction(label: 'Delete', icon: EveryIcon.delete, destructive: true, onSelected: _delete),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: AdaptiveIcon(EveryIcon.more, size: 14, color: theme.textMuted),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _export() => exportSession(context, ref, widget.info);

  Future<void> _rename() => renameSession(context, ref, widget.info);

  Future<void> _delete() async {
    final selected = widget.selected;
    if (await deleteSession(context, ref, widget.info) && selected && mounted) context.go(Routes.code);
  }

  static String _age(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h';
    return '${d.inDays}d';
  }
}

/// One of a harness's own earlier sessions for the folder (started in its CLI, or one EveryAI no longer lists):
/// harness and model, title, when and how long, branch. Picking it resumes it on that harness; one that can't
/// resume yet is greyed with what is in the way ([blocked]).
class PastSessionTile extends StatefulWidget {
  const PastSessionTile({
    super.key,
    required this.past,
    required this.label,
    required this.onOpen,
    this.blocked,
    this.busy = false,
  });

  final PastSession past;

  /// The harness's name.
  final String label;
  final String? blocked;
  final bool busy;
  final VoidCallback? onOpen;

  @override
  State<PastSessionTile> createState() => _PastSessionTileState();
}

class _PastSessionTileState extends State<PastSessionTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final p = widget.past;
    final enabled = widget.blocked == null && widget.onOpen != null;
    final meta = [
      [widget.label, if (p.model case final m? when m.isNotEmpty) m].join(' · '),
      _SessionTileState._age(p.lastActive),
      if (p.turns case final t?) t == 1 ? '1 turn' : '$t turns',
      if (p.branch case final b? when b.isNotEmpty) b,
    ].join(' · ');
    final title = p.title.length > 90 ? '${p.title.substring(0, 89)}…' : p.title;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: FocusableActionDetector(
        enabled: enabled,
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onOpen?.call())},
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? widget.onOpen : null,
          child: Semantics(
            button: true,
            enabled: enabled,
            label: '$title, ${widget.label}${widget.blocked == null ? '' : ', ${widget.blocked}'}',
            child: Opacity(
              opacity: widget.blocked == null ? 1 : 0.5,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 1),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: _hover && enabled ? theme.text.withValues(alpha: 0.05) : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    HarnessLogo(p.harness, size: 18, label: widget.label),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.type.callout.tint(theme.text),
                          ),
                          Text(
                            widget.blocked ?? meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.type.caption.tint(theme.textMuted),
                          ),
                        ],
                      ),
                    ),
                    if (widget.busy) Text('Opening…', style: theme.type.caption.tint(theme.textMuted)),
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

/// The terminal on Code home, outside any session: tabs of shells that start in the home folder (`C:\\` on
/// Windows), for making a folder or running `git init` before a session. Its top edge drags to resize; the height
/// is kept in Preferences `code.home.terminal_height`.
class _HomeTerminal extends ConsumerStatefulWidget {
  const _HomeTerminal({required this.maxHeight, required this.onClose});

  final double maxHeight;
  final VoidCallback onClose;

  @override
  ConsumerState<_HomeTerminal> createState() => _HomeTerminalState();
}

class _HomeTerminalState extends ConsumerState<_HomeTerminal> {
  static const _heightKey = 'code.home.terminal_height';
  late double _height = double.tryParse(ref.read(preferencesProvider)[_heightKey] ?? '') ?? 300;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final height = _height.clamp(160.0, widget.maxHeight.clamp(160.0, double.infinity));
    return SizedBox(
      key: const ValueKey('code-home.terminal-panel'),
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: theme.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MouseRegion(
              cursor: SystemMouseCursors.resizeRow,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (d) => setState(() => _height = (height - d.delta.dy)),
                onVerticalDragEnd: (_) => ref.read(preferencesProvider)[_heightKey] = '${height.round()}',
                child: const SizedBox(height: 6),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
              child: Row(
                children: [
                  Expanded(child: Text('Terminal', style: theme.type.callout.medium.tint(theme.text))),
                  KitIconButton(icon: EveryIcon.close, tooltip: 'Hide terminal', size: 14, onPressed: widget.onClose),
                ],
              ),
            ),
            Expanded(
              child: TerminalTabsView(owner: homeTerminalOwner, workingDir: terminalHomeDir, onToggle: widget.onClose),
            ),
          ],
        ),
      ),
    );
  }
}

/// Code home's terminal toggle: a small accent-bordered chip ("Terminal"), filled while the terminal is open, so it
/// stands out in the empty top bar.
class _TerminalButton extends StatefulWidget {
  const _TerminalButton({required this.open, required this.onPressed});

  final bool open;
  final VoidCallback onPressed;

  @override
  State<_TerminalButton> createState() => _TerminalButtonState();
}

class _TerminalButtonState extends State<_TerminalButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final fill = widget.open ? 0.22 : (_hover ? 0.16 : 0.08);
    return Semantics(
      button: true,
      selected: widget.open,
      label: widget.open ? 'Hide terminal' : 'Terminal',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          key: const ValueKey('code-home.terminal'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: theme.accent.withValues(alpha: fill),
              border: Border.all(color: theme.accent.withValues(alpha: widget.open ? 0.9 : 0.6)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AdaptiveIcon(EveryIcon.command, size: 14, color: theme.accent),
                const SizedBox(width: 6),
                Text('Terminal', style: theme.type.callout.medium.tint(theme.accent)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
