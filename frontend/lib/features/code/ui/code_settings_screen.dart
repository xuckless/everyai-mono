import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../code_providers.dart';
import '../../../core/ui/selection.dart';
import '../code_settings_providers.dart';
import '../domain/code_session.dart';
import 'code_slash_host.dart' show switchCodeAgent;

/// The tabs of the Code settings screen.
enum CodeSettingsTab {
  prompt('System prompt'),
  json('settings.json'),
  effective('Effective');

  const CodeSettingsTab(this.label);
  final String label;

  static CodeSettingsTab parse(Object? v) => values.where((t) => t.name == v).firstOrNull ?? json;
}

/// Code settings in layers (global, project, session) with a raw JSON
/// editor per layer, the overarching system prompts, and the merged result.
/// The layers are views of the app's stores (see [layerJson]); saving writes
/// back into those stores.
class CodeSettingsScreen extends ConsumerStatefulWidget {
  const CodeSettingsScreen({
    super.key,
    this.projectId,
    this.sessionId,
    this.scope = SettingsScope.global,
    this.tab = CodeSettingsTab.json,
  });

  final String? projectId;
  final String? sessionId;
  final SettingsScope scope;
  final CodeSettingsTab tab;

  @override
  ConsumerState<CodeSettingsScreen> createState() => _CodeSettingsScreenState();
}

class _CodeSettingsScreenState extends ConsumerState<CodeSettingsScreen> {
  late String? _projectId = widget.projectId;
  late SettingsScope _scope = _available(widget.scope);
  late CodeSettingsTab _tab = widget.tab;
  final _text = TextEditingController();
  List<String> _errors = const [];

  /// What the editor was loaded from, to tell edits from store changes.
  String _loaded = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  SettingsScope _available(SettingsScope s) => switch (s) {
    SettingsScope.session when widget.sessionId == null =>
      _projectId == null ? SettingsScope.global : SettingsScope.project,
    SettingsScope.project when _projectId == null => SettingsScope.global,
    _ => s,
  };

  CodeSessionInfo? get _session {
    final id = widget.sessionId;
    return id == null ? null : ref.read(codeSessionsProvider).where((s) => s.id == id).firstOrNull;
  }

  SessionLayer? _sessionLayer({required bool watch}) {
    final id = widget.sessionId;
    if (id == null) return null;
    final sessions = watch ? ref.watch(codeSessionsProvider) : ref.read(codeSessionsProvider);
    final info = sessions.where((s) => s.id == id).firstOrNull;
    if (info == null) return null;
    final budgets = watch ? ref.watch(codeSettingsProvider).budgets : ref.read(codeSettingsProvider).budgets;
    return (model: info.model, effort: info.effort, mode: info.mode, budgetUsd: budgets[id]);
  }

  String _current({bool watch = false}) {
    final sources = codeSettingsSources(
      ref,
      session: _sessionLayer(watch: watch),
      watch: watch,
    );
    return switch (_tab) {
      CodeSettingsTab.prompt => sources.settings.promptFor(_scope == SettingsScope.global ? null : _projectId),
      CodeSettingsTab.json => prettyJson(layerJson(_scope, sources, projectId: _projectId)),
      CodeSettingsTab.effective => prettyJson(effectiveJson(sources, projectId: _projectId)),
    };
  }

  void _reload() {
    _loaded = _current();
    _text.text = _loaded;
    _errors = const [];
  }

  void _go({SettingsScope? scope, CodeSettingsTab? tab, String? projectId}) => setState(() {
    if (projectId != null) _projectId = projectId;
    if (scope != null) _scope = _available(scope);
    if (tab != null) _tab = tab;
    _reload();
  });

  Future<void> _save() async {
    if (_tab == CodeSettingsTab.prompt) {
      ref.read(codeSettingsProvider.notifier).setPrompt(_scope == SettingsScope.global ? null : _projectId, _text.text);
      setState(_reload);
      showAdaptiveToast(context, 'Saved. New sessions get it.');
      return;
    }
    final parsed = parseLayer(_scope, _text.text);
    final edit = parsed.edit;
    if (edit == null) {
      setState(() => _errors = parsed.errors);
      return;
    }
    if (_scope == SettingsScope.session) {
      await _applySession(edit);
    } else {
      ref.read(codeSettingsProvider.notifier).applyLayer(_scope, edit, projectId: _projectId);
    }
    if (!mounted) return;
    setState(_reload);
    showAdaptiveToast(context, 'Saved');
  }

  Future<void> _applySession(LayerEdit edit) async {
    final info = _session;
    if (info == null) return;
    final controller = ref.read(codeSessionProvider(info.id).notifier);
    if (edit.mode case final m? when m != info.mode) await controller.setMode(m);
    final model = edit.model == null || edit.model == info.model ? null : edit.model;
    final effort = edit.effort == null || edit.effort == info.effort ? null : edit.effort;
    if ((model != null || effort != null) && mounted) {
      await switchCodeAgent(context, ref, info.id, model: model, effort: effort);
    }
    if (edit.budgetUsd != null || edit.clearBudget) {
      ref.read(codeSettingsProvider.notifier).setBudget(info.id, edit.budgetUsd);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final projects = ref.watch(codeProjectsProvider);
    // Store changes made elsewhere show up unless the user is mid-edit.
    final current = _current(watch: true);
    if (current != _loaded && _text.text == _loaded) {
      _loaded = current;
      _text.text = current;
    }
    final project = projects.where((p) => p.id == _projectId).firstOrNull;
    final readOnly =
        _tab == CodeSettingsTab.effective || (_tab == CodeSettingsTab.prompt && _scope == SettingsScope.session);

    Widget chip(String label, bool on, VoidCallback? onTap, {Key? key}) => GestureDetector(
      key: key,
      onTap: onTap,
      child: MouseRegion(
        cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: Container(
          margin: const EdgeInsets.only(right: 6, bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: on ? theme.accent.withValues(alpha: 0.14) : null,
            border: Border.all(color: on ? theme.accent : theme.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(color: onTap == null && !on ? theme.textMuted : theme.text, fontSize: 13),
          ),
        ),
      ),
    );

    final blurb = switch (_tab) {
      CodeSettingsTab.prompt when _scope == SettingsScope.session =>
        'System prompts are set for every project or for one project.',
      CodeSettingsTab.prompt =>
        'Added to the end of the agent\'s system prompt in every new session'
            '${_scope == SettingsScope.global ? '' : ' in ${project?.name ?? 'this project'}'}. Fixed for a '
            'session once it starts, so prompt caching keeps working.',
      CodeSettingsTab.json => switch (_scope) {
        SettingsScope.global =>
          'systemPrompt, permissions {allow, deny}, mcpServers and skills {disabled}. A key left out is cleared. '
              'MCP approvals and skill trust stay in their own screens.',
        SettingsScope.project =>
          'systemPrompt, permissions and mcpServers for ${project?.name ?? 'this project'}, on top of the global '
              'layer. A key left out is cleared.',
        SettingsScope.session => 'model, effort, mode and budgetUsd for this session; they apply at once.',
      },
      CodeSettingsTab.effective =>
        'Every layer merged: what ${_session == null ? 'a new session here' : 'this session'} runs with. '
            'Repository files (.everyai/settings.json) add project rules and deny rules on top.',
    };

    return AdaptivePage(
      title: 'Code settings',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Wrap(
            children: [
              for (final s in SettingsScope.values)
                chip(
                  key: ValueKey('code-settings.scope.${s.name}'),
                  s.label,
                  _scope == s && _tab != CodeSettingsTab.effective,
                  _available(s) == s && _tab != CodeSettingsTab.effective ? () => _go(scope: s) : null,
                ),
              const SizedBox(width: 12),
              for (final t in CodeSettingsTab.values)
                chip(key: ValueKey('code-settings.tab.${t.name}'), t.label, _tab == t, () => _go(tab: t)),
            ],
          ),
          if (projects.isNotEmpty && _scope != SettingsScope.global)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: AdaptiveMenuButton(
                actions: [
                  for (final p in projects)
                    MenuAction(
                      label: p.name,
                      checked: p.id == _projectId,
                      onSelected: () => _go(projectId: p.id),
                    ),
                ],
                child: Text(
                  'Project: ${project?.name ?? 'choose…'}',
                  style: TextStyle(color: theme.accent, fontSize: 13),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(blurb, style: TextStyle(color: theme.textMuted, fontSize: 12.5)),
          ),
          if (readOnly)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: theme.border),
                borderRadius: BorderRadius.circular(theme.radius),
              ),
              child: AdaptiveSelectionArea(
                child: Text(
                  _text.text.isEmpty ? '(none)' : _text.text,
                  style: TextStyle(fontFamily: 'SourceCodePro', fontSize: 12.5, color: theme.text),
                ),
              ),
            )
          else
            DefaultTextStyle.merge(
              style: TextStyle(fontFamily: _tab == CodeSettingsTab.json ? 'SourceCodePro' : null, fontSize: 12.5),
              child: AdaptiveTextField(
                key: ValueKey('code-settings.editor.${_scope.name}.${_tab.name}'),
                controller: _text,
                minLines: 12,
                maxLines: 30,
                keyboardType: TextInputType.multiline,
                placeholder: _tab == CodeSettingsTab.prompt
                    ? 'e.g. Answer in British English. Prefer small PRs.'
                    : null,
                onChanged: (_) => setState(() => _errors = const []),
              ),
            ),
          for (final e in _errors)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(e, style: TextStyle(color: theme.danger, fontSize: 12.5)),
            ),
          if (!readOnly)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  AdaptiveButton(key: const ValueKey('code-settings.save'), label: 'Save', onPressed: _save),
                  const SizedBox(width: 8),
                  AdaptiveButton(
                    label: 'Revert',
                    emphasis: ButtonEmphasis.secondary,
                    onPressed: () => setState(_reload),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
