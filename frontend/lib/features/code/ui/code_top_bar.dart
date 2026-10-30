import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../agents/agents_providers.dart';
import '../../billing/billing_providers.dart' show formatMicros;
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../../skills/skills_providers.dart' show installedSkillsProvider, skillSettingsProvider;
import '../../usage/ui/usage_meter.dart' show ContextRing, UsageBreakdown;
import '../../usage/usage_totals.dart';
import '../code_providers.dart';
import '../code_settings_providers.dart';
import '../domain/agent_mode.dart';
import '../mcp_providers.dart';
import '../permissions_providers.dart';
import 'code_settings_screen.dart' show CodeSettingsTab;

/// The session's top bar: session-level controls beside the title. [agentMenu]
/// is the Harness → Model → Effort menu; the rest are popovers (never bottom
/// sheets): mode, agents, settings shortcuts, usage against the budget, and
/// the Ultra slot.
class CodeTopBar extends ConsumerWidget {
  const CodeTopBar({super.key, required this.sessionId, required this.agentMenu});

  final String sessionId;
  final Widget agentMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(codeSessionsProvider.select((all) => all.where((s) => s.id == sessionId).firstOrNull));
    if (info == null) return const SizedBox.shrink();
    final state = ref.watch(codeSessionProvider(sessionId));
    final controller = ref.read(codeSessionProvider(sessionId).notifier);
    final ultra = ref.watch(codeUltraSlotProvider);
    final wide = MediaQuery.sizeOf(context).width >= 1000;

    // The session controller stops the run at the budget; this only says so.
    ref.listen(codeUsageProvider(sessionId), (before, after) {
      final budget = ref.read(codeSettingsProvider).budgets[sessionId];
      final was = before?.value?.chargedMicros ?? 0;
      final now = after.value?.chargedMicros ?? was;
      if (!crossedBudget(was, now, budget)) return;
      if (context.mounted) {
        showAdaptiveToast(context, 'Stopped: this session reached its ${formatMicros((budget! * 1e6).round())} budget');
      }
    });

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 200), child: agentMenu),
        // Mode is in the composer too, so narrow windows drop it (and agents) here.
        if (wide) ...[
          _ModeChip(mode: state.mode, onChanged: controller.setMode),
          _AgentsChip(projectId: info.projectId),
        ],
        _SettingsChip(projectId: info.projectId, sessionId: sessionId),
        BudgetChip(sessionId: sessionId, model: info.model),
        ?ultra?.call(context, sessionId),
      ],
    );
  }
}

/// A compact outlined chip that opens a popover.
class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.icon, this.color, this.semantics});

  final String label;
  final EveryIcon? icon;
  final Color? color;
  final String? semantics;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final fg = color ?? theme.textMuted;
    return Semantics(
      button: true,
      label: semantics ?? label,
      child: Container(
        margin: const EdgeInsets.only(left: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: color?.withValues(alpha: 0.6) ?? theme.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              AdaptiveIcon(icon!, size: 13, color: fg),
              if (label.isNotEmpty) const SizedBox(width: 5),
            ],
            if (label.isNotEmpty)
              Text(
                label,
                maxLines: 1,
                style: TextStyle(color: fg, fontSize: 12.5, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            const SizedBox(width: 4),
            AdaptiveIcon(EveryIcon.chevronDown, size: 10, color: fg),
          ],
        ),
      ),
    );
  }
}

Widget _check(EveryTheme theme, bool on) =>
    on ? AdaptiveIcon(EveryIcon.check, size: 14, color: theme.accent) : const SizedBox(width: 14);

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.mode, required this.onChanged});

  final AgentMode mode;
  final Future<void> Function(AgentMode) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return AnchoredPopover(
      width: 300,
      builder: (context, close) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PopoverHeader('Mode'),
            for (final m in AgentMode.values)
              PopoverRow(
                key: ValueKey('top-bar.mode.${m.name}'),
                title: m.label,
                subtitle: m.description,
                selected: m == mode,
                trailing: _check(theme, m == mode),
                onTap: () {
                  close();
                  if (m != mode) onChanged(m).ignore();
                },
              ),
          ],
        ),
      ),
      child: _Chip(label: mode.label, semantics: 'Mode: ${mode.label}'),
    );
  }
}

/// The agent library's agents this project may hand work to, with switches.
class _AgentsChip extends ConsumerWidget {
  const _AgentsChip({required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(agentLibraryProvider).value ?? const <AgentDefinition>[];
    final settings = ref.watch(agentLibrarySettingsProvider);
    final winners = agentWinners(library, projectId).values.toList()..sort((a, b) => a.name.compareTo(b.name));
    final active = sessionAgents(library, settings, projectId).length;
    return AnchoredPopover(
      width: 340,
      builder: (context, close) => _AgentsPanel(agents: winners, projectId: projectId, close: close),
      child: _Chip(icon: EveryIcon.spark, label: '$active', semantics: 'Agents: $active on'),
    );
  }
}

class _AgentsPanel extends ConsumerWidget {
  const _AgentsPanel({required this.agents, required this.projectId, required this.close});

  final List<AgentDefinition> agents;
  final String projectId;
  final VoidCallback close;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final settings = ref.watch(agentLibrarySettingsProvider);
    final store = ref.read(agentLibrarySettingsProvider.notifier);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PopoverHeader('Main agent'),
          const PopoverRow(
            title: 'EveryAI agent',
            subtitle: 'Runs the session; the agents below take the work it hands off',
            selected: true,
          ),
          const PopoverHeader('Subagents · from the next session'),
          if (agents.isEmpty) const PopoverRow(title: 'No agents yet', subtitle: 'Add some in Settings → Agents'),
          for (final a in agents)
            PopoverRow(
              key: ValueKey('top-bar.agent.${a.name}'),
              title: a.name,
              subtitle: settings.trustedNow(a)
                  ? [a.source.label, if (a.oneLine.isNotEmpty) a.oneLine].join(' · ')
                  : 'Project agent: trust it in Settings → Agents first',
              trailing: _check(theme, settings.active(a)),
              onTap: settings.trustedNow(a) ? () => store.setEnabled(a, !settings.enabled(a)) : null,
            ),
          PopoverRow(
            key: const ValueKey('top-bar.agents.manage'),
            title: 'Manage agents…',
            onTap: () {
              close();
              context.go(Routes.agents);
            },
          ),
        ],
      ),
    );
  }
}

/// Shortcuts to the settings a session runs with.
class _SettingsChip extends ConsumerWidget {
  const _SettingsChip({required this.projectId, required this.sessionId});

  final String projectId;
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(codePermissionsProvider).rulesFor(projectId);
    final mcp = ref.watch(codeMcpServersProvider).serversFor(projectId).where((s) => s.active).length;
    final skillSettings = ref.watch(skillSettingsProvider);
    final skills = (ref.watch(installedSkillsProvider).value ?? const []).where(skillSettings.active).length;
    final prompts = ref.watch(codeSettingsProvider);
    final promptCount = [prompts.globalPrompt, prompts.promptFor(projectId)].where((p) => p.isNotEmpty).length;

    String plural(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

    return AnchoredPopover(
      width: 320,
      builder: (context, close) {
        void open(String location) {
          close();
          context.go(location);
        }

        String settingsAt(SettingsScope scope, CodeSettingsTab tab) =>
            Routes.codeSettings(projectId: projectId, sessionId: sessionId, scope: scope.name, tab: tab.name);

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const PopoverHeader('Session settings'),
              PopoverRow(
                key: const ValueKey('top-bar.settings.permissions'),
                title: 'Permissions',
                subtitle: '${plural(rules.allow.length, 'allow rule')} · ${plural(rules.deny.length, 'deny rule')}',
                onTap: () => open(settingsAt(SettingsScope.project, CodeSettingsTab.json)),
              ),
              PopoverRow(
                key: const ValueKey('top-bar.settings.mcp'),
                title: 'MCP servers',
                subtitle: '${plural(mcp, 'server')} on',
                onTap: () => open(Routes.mcpServers),
              ),
              PopoverRow(
                key: const ValueKey('top-bar.settings.skills'),
                title: 'Skills',
                subtitle: '${plural(skills, 'skill')} on',
                onTap: () => open(Routes.skills),
              ),
              PopoverRow(
                key: const ValueKey('top-bar.settings.prompt'),
                title: 'System prompt',
                subtitle: promptCount == 0 ? 'None' : 'Global and project · ${plural(promptCount, 'prompt')} set',
                onTap: () => open(settingsAt(SettingsScope.project, CodeSettingsTab.prompt)),
              ),
              PopoverRow(
                key: const ValueKey('top-bar.settings.json'),
                title: 'settings.json…',
                subtitle: 'Global, project and session layers as JSON',
                onTap: () => open(settingsAt(SettingsScope.session, CodeSettingsTab.json)),
              ),
            ],
          ),
        );
      },
      child: const _Chip(icon: EveryIcon.settings, label: '', semantics: 'Session settings'),
    );
  }
}

/// The session's spending, against its budget when it has one; the popover
/// has the breakdown and sets the budget.
class BudgetChip extends ConsumerWidget {
  const BudgetChip({super.key, required this.sessionId, required this.model});

  final String sessionId;
  final String model;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final totals = ref.watch(codeUsageProvider(sessionId)).value ?? UsageTotals.zero;
    final budget = ref.watch(codeSettingsProvider.select((s) => s.budgets[sessionId]));
    final spec = ref.watch(modelCatalogProvider)[ModelId(model)];
    final fill = budgetFill(totals.chargedMicros, budget);
    final spent = formatMicros(totals.chargedMicros);
    final label = budget == null ? spent : '$spent / ${formatMicros((budget * 1e6).round())}';
    final color = fill == null || fill < 0.8
        ? null
        : fill >= 1
        ? theme.danger
        : theme.warning;
    return AnchoredPopover(
      width: 280,
      builder: (context, close) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UsageBreakdown(totals: totals, contextWindow: spec?.contextLength ?? 0, modelName: spec?.name),
          const PopoverHeader('Budget for this session'),
          for (final usd in [null, ...budgetPresets])
            PopoverRow(
              key: ValueKey('top-bar.budget.${usd ?? 'none'}'),
              title: usd == null ? 'No cap' : formatMicros((usd * 1e6).round()),
              subtitle: usd != null && totals.chargedMicros >= usd * 1e6 ? 'Already spent' : null,
              selected: usd == budget,
              trailing: _check(theme, usd == budget),
              onTap: () {
                close();
                ref.read(codeSettingsProvider.notifier).setBudget(sessionId, usd);
              },
            ),
          const SizedBox(height: 5),
        ],
      ),
      child: Container(
        margin: const EdgeInsets.only(left: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Chip(label: label, color: color, semantics: 'Usage $label'),
            if (fill != null) ...[const SizedBox(width: 5), ContextRing(fill: fill.clamp(0, 1).toDouble(), size: 14)],
          ],
        ),
      ),
    );
  }
}
