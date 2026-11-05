import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../settings/ui/settings_modal.dart' show closeSettings;
import '../../code_providers.dart' show codeProjectsProvider;
import '../../domain/agent_mode.dart';
import '../../domain/code_session.dart' show everyaiHarnessName;
import '../../drivers/driver_registry.dart' show driverRegistryProvider;
import '../schedule.dart';
import '../schedule_providers.dart';
import 'webhooks_part.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "Nov 5 09:00".
String whenLabel(DateTime t) =>
    '${_months[t.month - 1]} ${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Settings → Code → Scheduled tasks: prompts that start a Code session on a schedule, while the app is open.
class ScheduledTasksBody extends ConsumerStatefulWidget {
  const ScheduledTasksBody({super.key});

  @override
  ConsumerState<ScheduledTasksBody> createState() => _ScheduledTasksBodyState();
}

class _ScheduledTasksBodyState extends ConsumerState<ScheduledTasksBody> {
  /// The task in the form: a new one (id '') or an existing one.
  ScheduledTask? _editing;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final tasks = ref.watch(scheduledTasksProvider);
    final missed = ref.read(scheduledTasksProvider.notifier).missed;
    final running = ref.watch(scheduleRunnerProvider);
    final projects = ref.watch(codeProjectsProvider);
    final runner = ref.read(scheduleRunnerProvider.notifier);
    final ctl = ref.read(scheduledTasksProvider.notifier);
    final editing = _editing;

    Widget tile(ScheduledTask t) {
      final project = projects.where((p) => p.id == t.projectId).firstOrNull?.name ?? 'Project gone';
      final status = t.lastError != null
          ? (text: t.lastError!, bad: true)
          : missed[t.id] != null
          ? (text: 'Missed ${whenLabel(missed[t.id]!)}. Run now to start it.', bad: false)
          : t.lastRun != null
          ? (text: 'Last run ${whenLabel(t.lastRun!)}', bad: false)
          : (text: 'Not run yet', bad: false);
      return AdaptiveListTile(
        title: Text(t.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$project · ${t.schedule.label}${t.enabled && t.nextRun != null ? ' · next ${whenLabel(t.nextRun!)}' : ''}',
              style: theme.type.caption.tint(theme.textMuted),
            ),
            Text(status.text, style: theme.type.caption.tint(status.bad ? theme.danger : theme.textMuted)),
          ],
        ),
        onTap: () => setState(() => _editing = t),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AdaptiveSwitch(value: t.enabled, onChanged: (on) => ctl.setEnabled(t.id, on)),
            AdaptiveMenuButton(
              tooltip: 'More',
              actions: [
                MenuAction(
                  label: running.contains(t.id) ? 'Starting…' : 'Run now',
                  icon: EveryIcon.play,
                  onSelected: running.contains(t.id) ? () {} : () => runner.runNow(t.id),
                ),
                if (t.lastSessionId case final sid?)
                  MenuAction(
                    label: 'Open last session',
                    icon: EveryIcon.external,
                    onSelected: () {
                      final router = GoRouter.of(context);
                      closeSettings(context);
                      router.go(Routes.codeSession(sid));
                    },
                  ),
                MenuAction(label: 'Edit', icon: EveryIcon.edit, onSelected: () => setState(() => _editing = t)),
                MenuAction(
                  label: 'Delete',
                  icon: EveryIcon.delete,
                  destructive: true,
                  onSelected: () => ctl.remove(t.id),
                ),
              ],
              child: const Padding(padding: EdgeInsets.all(6), child: AdaptiveIcon(EveryIcon.more, size: 16)),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 32),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Text(
            'Start a Code session on a schedule. Tasks run only while EveryAI is open on this computer; a run '
            'missed while it was closed waits for you to press Run now. Each one starts like a session you start '
            'yourself, with the same checks and permissions.',
            style: theme.type.callout.tint(theme.textMuted),
          ),
        ),
        if (tasks.isEmpty && editing == null)
          AdaptiveListTile(title: Text('No scheduled tasks yet', style: theme.type.body.tint(theme.textMuted))),
        for (final t in tasks)
          if (editing?.id == t.id)
            _TaskForm(key: ValueKey('edit-${t.id}'), initial: t, onCancel: _close, onSave: _save)
          else
            tile(t),
        if (editing != null && editing.id.isEmpty)
          _TaskForm(key: const ValueKey('edit-new'), initial: editing, onCancel: _close, onSave: _save),
        if (editing == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: AdaptiveButton(
                label: 'Add task',
                emphasis: ButtonEmphasis.secondary,
                icon: const AdaptiveIcon(EveryIcon.add, size: 14),
                onPressed: projects.isEmpty
                    ? null
                    : () => setState(
                        () => _editing = ScheduledTask(
                          id: '',
                          name: '',
                          projectId: projects.first.id,
                          prompt: '',
                          schedule: Schedule.daily(9, 0),
                        ),
                      ),
              ),
            ),
          ),
        if (projects.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text('Open a project in Code first.', style: theme.type.caption.tint(theme.textMuted)),
          ),
        const WebhooksPart(),
      ],
    );
  }

  void _close() => setState(() => _editing = null);

  void _save(ScheduledTask task) {
    final ctl = ref.read(scheduledTasksProvider.notifier);
    ctl.put(
      task.id.isEmpty
          ? ctl.newTask(
              name: task.name,
              projectId: task.projectId,
              prompt: task.prompt,
              schedule: task.schedule,
              harness: task.harness,
              model: task.model,
              mode: task.mode,
            )
          : task,
    );
    _close();
  }
}

enum _Kind {
  daily('Every day'),
  weekdays('Weekdays'),
  hours('Every few hours'),
  cron('Cron expression');

  const _Kind(this.label);
  final String label;
}

/// "09:30" as (9, 30), or null.
(int, int)? parseTime(String text) {
  final m = RegExp(r'^\s*(\d{1,2}):(\d{2})\s*$').firstMatch(text);
  if (m == null) return null;
  final (h, min) = (int.parse(m[1]!), int.parse(m[2]!));
  return h > 23 || min > 59 ? null : (h, min);
}

class _TaskForm extends ConsumerStatefulWidget {
  const _TaskForm({super.key, required this.initial, required this.onCancel, required this.onSave});

  final ScheduledTask initial;
  final VoidCallback onCancel;
  final ValueChanged<ScheduledTask> onSave;

  @override
  ConsumerState<_TaskForm> createState() => _TaskFormState();
}

class _TaskFormState extends ConsumerState<_TaskForm> {
  late final _name = TextEditingController(text: widget.initial.name);
  late final _prompt = TextEditingController(text: widget.initial.prompt);
  late final _model = TextEditingController(text: widget.initial.model);
  late final _time = TextEditingController(text: _initialTime());
  late final _hours = TextEditingController(text: '${widget.initial.schedule.hours ?? 6}');
  late final _cron = TextEditingController(text: widget.initial.schedule.cron ?? '0 9 * * 1-5');
  late String _projectId = widget.initial.projectId;
  late String _harness = widget.initial.harness;
  late AgentMode _mode = widget.initial.mode;
  late _Kind _kind = _initialKind();

  _Kind _initialKind() {
    final s = widget.initial.schedule;
    if (s.hours != null) return _Kind.hours;
    final m = RegExp(r'^\d+ \d+ \* \* (\*|1-5)$').firstMatch(s.cron ?? '');
    return m == null ? _Kind.cron : (m[1] == '*' ? _Kind.daily : _Kind.weekdays);
  }

  String _initialTime() {
    final m = RegExp(r'^(\d+) (\d+) ').firstMatch(widget.initial.schedule.cron ?? '');
    return m == null ? '09:00' : '${m[2]!.padLeft(2, '0')}:${m[1]!.padLeft(2, '0')}';
  }

  @override
  void dispose() {
    for (final c in [_name, _prompt, _model, _time, _hours, _cron]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The schedule the fields spell, or why not.
  ({Schedule? schedule, String? problem}) _schedule() {
    switch (_kind) {
      case _Kind.daily || _Kind.weekdays:
        final t = parseTime(_time.text);
        if (t == null) return (schedule: null, problem: 'Time as HH:MM, for example 09:30.');
        return (
          schedule: _kind == _Kind.daily ? Schedule.daily(t.$1, t.$2) : Schedule.weekdays(t.$1, t.$2),
          problem: null,
        );
      case _Kind.hours:
        final h = int.tryParse(_hours.text.trim());
        if (h == null || h < 1 || h > 168) return (schedule: null, problem: 'Hours between 1 and 168.');
        return (schedule: Schedule.everyHours(h), problem: null);
      case _Kind.cron:
        final s = Schedule.custom(_cron.text);
        return (schedule: s.problem == null ? s : null, problem: s.problem);
    }
  }

  String? get _missing {
    if (_name.text.trim().isEmpty) return 'Give the task a name.';
    if (_prompt.text.trim().isEmpty) return 'Write what the agent should do.';
    return null;
  }

  void _submit() {
    final s = _schedule().schedule;
    if (s == null || _missing != null) return;
    widget.onSave(
      widget.initial.copyWith(
        name: _name.text.trim(),
        projectId: _projectId,
        prompt: _prompt.text.trim(),
        schedule: s,
        harness: _harness,
        model: _model.text.trim(),
        mode: _mode,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final projects = ref.watch(codeProjectsProvider);
    final drivers = ref.watch(driverRegistryProvider).listed.toList();
    final (:schedule, :problem) = _schedule();
    final upcoming = schedule?.upcoming(ref.read(scheduleClockProvider)(), 3) ?? const [];
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Text(text, style: theme.type.caption.tint(theme.textMuted)),
    );
    final lead = drivers.where((d) => d.info.id == _harness).firstOrNull?.info.label ?? _harness;
    final canSave = schedule != null && _missing == null;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdaptiveTextField(
            controller: _name,
            placeholder: 'Name (Morning triage, Nightly tests, …)',
            onChanged: (_) => setState(() {}),
          ),
          label('Project, lead and model'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AdaptiveMenuButton(
                actions: [
                  for (final p in projects)
                    MenuAction(
                      label: p.name,
                      checked: p.id == _projectId,
                      onSelected: () => setState(() => _projectId = p.id),
                    ),
                ],
                child: MenuTrigger(projects.where((p) => p.id == _projectId).firstOrNull?.name ?? 'Pick a project'),
              ),
              AdaptiveMenuButton(
                actions: [
                  for (final d in drivers)
                    MenuAction(
                      label: d.info.label,
                      checked: d.info.id == _harness,
                      onSelected: () => setState(() => _harness = d.info.id),
                    ),
                ],
                child: MenuTrigger(lead),
              ),
              AdaptiveMenuButton(
                actions: [
                  for (final m in AgentMode.values.where((m) => m != AgentMode.bypass))
                    MenuAction(label: m.label, checked: m == _mode, onSelected: () => setState(() => _mode = m)),
                ],
                child: MenuTrigger(_mode.label),
              ),
            ],
          ),
          const SizedBox(height: 8),
          AdaptiveTextField(
            controller: _model,
            placeholder: _harness == everyaiHarnessName
                ? 'Model id (empty: the one picked in Code)'
                : 'Model (empty: the one picked for this lead)',
          ),
          if (_mode == AgentMode.fullAuto)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Full auto runs commands and edits with nobody watching. The safety floor and your deny rules still apply.',
                style: theme.type.caption.tint(theme.warning),
              ),
            ),
          label('What it should do'),
          AdaptiveTextField(
            controller: _prompt,
            minLines: 3,
            maxLines: 8,
            placeholder: 'The first message of the session',
            onChanged: (_) => setState(() {}),
          ),
          label('When'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AdaptiveMenuButton(
                actions: [
                  for (final k in _Kind.values)
                    MenuAction(label: k.label, checked: k == _kind, onSelected: () => setState(() => _kind = k)),
                ],
                child: MenuTrigger(_kind.label),
              ),
              SizedBox(
                width: _kind == _Kind.cron ? 220 : 110,
                child: switch (_kind) {
                  _Kind.daily || _Kind.weekdays => AdaptiveTextField(
                    controller: _time,
                    placeholder: '09:00',
                    onChanged: (_) => setState(() {}),
                  ),
                  _Kind.hours => AdaptiveTextField(
                    controller: _hours,
                    placeholder: 'Hours',
                    onChanged: (_) => setState(() {}),
                  ),
                  _Kind.cron => AdaptiveTextField(
                    controller: _cron,
                    placeholder: '0 9 * * 1-5',
                    onChanged: (_) => setState(() {}),
                  ),
                },
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              problem ?? (upcoming.isEmpty ? 'It never runs.' : 'Next: ${upcoming.map(whenLabel).join(', ')}'),
              style: theme.type.caption.tint(problem == null ? theme.textMuted : theme.danger),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AdaptiveButton(label: 'Cancel', emphasis: ButtonEmphasis.secondary, onPressed: widget.onCancel),
                const SizedBox(width: 8),
                AdaptiveButton(label: 'Save', onPressed: canSave ? _submit : null),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
