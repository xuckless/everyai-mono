import '../../../core/ui/brand.dart';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../attachments/attachment.dart';
import '../../models/models_providers.dart';
import '../../../core/platform/platform_kind.dart';
import '../code_providers.dart';
import '../sidecar/sidecar.dart';
import '../domain/agent_mode.dart';
import '../domain/code_session.dart';
import 'code_composer.dart';
import 'session_view.dart';

/// Where demo sessions "run" (the mock harness ignores the folder).
const demoProjectPath = '${demoScheme}counter-app';

/// Code landing: pick a project, describe the task, start a session.
class CodeHome extends ConsumerStatefulWidget {
  const CodeHome({super.key});

  @override
  ConsumerState<CodeHome> createState() => _CodeHomeState();
}

class _CodeHomeState extends ConsumerState<CodeHome> {
  String? _projectId;
  AgentMode _mode = AgentMode.ask;
  bool _starting = false;

  Future<CodeProject?> _openFolder() async {
    final path = await getDirectoryPath(confirmButtonText: 'Open');
    if (path == null) return null;
    final project = ref.read(codeProjectsProvider.notifier).add(path);
    setState(() => _projectId = project.id);
    return project;
  }

  @override
  void initState() {
    super.initState();
    // Warm the agent server up while the user types; errors surface on start.
    if (Host.isDesktop) ref.read(sidecarProvider).endpoint().ignore();
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

  void _addDemo() {
    final project = ref.read(codeProjectsProvider.notifier).add(demoProjectPath, name: 'counter-app (demo)');
    setState(() => _projectId = project.id);
  }

  Future<void> _start(CodeProject project, String prompt, List<Attachment> files) async {
    setState(() => _starting = true);
    try {
      final info = await ref
          .read(codeSessionsProvider.notifier)
          .start(
            project: project,
            prompt: prompt,
            model: ref.read(defaultModelProvider).id.value,
            mode: _mode,
            files: files,
          );
      if (mounted) context.go(Routes.codeSession(info.id));
    } on Object catch (e) {
      if (mounted) showAdaptiveToast(context, 'Couldn\'t start the session: $e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final projects = ref.watch(codeProjectsProvider);
    final project = projects.where((p) => p.id == _projectId).firstOrNull ?? projects.firstOrNull;
    final sessions = ref.watch(codeSessionsProvider).where((s) => s.projectId == project?.id).take(8).toList();

    return AdaptivePage(
      title: '',
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 48),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const BrandGlyph('code', active: true, size: 26),
                    const SizedBox(width: 12),
                    Text(
                      project == null ? 'Code with an agent' : 'What should we build?',
                      style: TextStyle(
                        color: theme.text,
                        fontSize: 26,
                        fontWeight: FontWeight.w400,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                if (project == null)
                  _NoProjects(onOpen: _openFolder, onSample: _addSample, onDemo: _addDemo)
                else ...[
                  CodeComposer(
                    busy: _starting,
                    mode: _mode,
                    minLines: 3,
                    placeholder: 'Describe a change, a bug to fix, or a feature to build',
                    onModeChanged: (m) => setState(() => _mode = m),
                    onSend: (text, files) => _start(project, text, files),
                    leading: _ProjectPicker(
                      project: project,
                      projects: projects,
                      onPick: (p) => setState(() => _projectId = p.id),
                      onOpen: _openFolder,
                      onSample: _addSample,
                      onDemo: _addDemo,
                    ),
                    trailing: Text(
                      ref.watch(defaultModelProvider).name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: theme.textMuted, fontSize: 12.5),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _starting && !isDemoPath(project.path)
                        ? 'Starting the agent…'
                        : 'The agent works in ${isDemoPath(project.path) ? 'a demo project with a scripted agent' : project.path}. '
                              '${_mode.description}.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.textMuted, fontSize: 12.5),
                  ),
                  if (sessions.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    Text(
                      'Recent sessions',
                      style: TextStyle(color: theme.textMuted, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    for (final s in sessions) SessionTile(info: s, onOpen: () => context.go(Routes.codeSession(s.id))),
                  ],
                ],
              ],
            ),
          ),
        ),
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
    final theme = EveryTheme.of(context);
    return Column(
      children: [
        Text(
          'Open a project folder and describe what you want. The agent reads the code, runs commands and edits '
          'files, asking before anything risky.',
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.textMuted, fontSize: 14, height: 1.45),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.center,
          children: [
            AdaptiveButton(label: 'Open folder…', onPressed: onOpen),
            AdaptiveButton(label: 'Sample project', emphasis: ButtonEmphasis.secondary, onPressed: onSample),
            AdaptiveButton(label: 'Scripted demo', emphasis: ButtonEmphasis.plain, onPressed: onDemo),
          ],
        ),
      ],
    );
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
      builder: (context, close) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PopoverHeader('Projects'),
            for (final p in projects)
              PopoverRow(
                title: p.name,
                subtitle: isDemoPath(p.path) ? 'Scripted demo' : p.path,
                selected: p.id == project.id,
                onTap: () {
                  close();
                  onPick(p);
                },
              ),
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
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AdaptiveIcon(EveryIcon.projects, size: 13, color: theme.textMuted),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                project.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.textMuted, fontSize: 12.5, fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: 4),
            AdaptiveIcon(EveryIcon.chevronDown, size: 11, color: theme.textMuted),
          ],
        ),
      ),
    );
  }
}

/// A session in a list: status dot, title, age.
class SessionTile extends ConsumerStatefulWidget {
  const SessionTile({super.key, required this.info, required this.onOpen, this.selected = false, this.dense = false});

  final CodeSessionInfo info;
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
    // Open sessions have a live status; the rest come from the agent server.
    final status = ref.exists(codeSessionProvider(widget.info.id))
        ? ref.watch(codeSessionProvider(widget.info.id).select((s) => s.status))
        : ref.watch(codeStatusesProvider.select((all) => all[widget.info.id])) ?? SessionStatus.idle;
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
          label: '${widget.info.title}, ${status.label}',
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
                StatusPill(status: status, dense: true),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.info.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: theme.text, fontSize: 13),
                  ),
                ),
                if (!widget.dense)
                  Text(_age(widget.info.createdAt), style: TextStyle(color: theme.textMuted, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _age(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h';
    return '${d.inDays}d';
  }
}
