import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/ui/adaptive.dart';
import '../../models/models_providers.dart';
import '../../slash/chat_actions.dart' show modelForQuery;
import '../../slash/slash_command.dart';
import '../agent_models.dart';
import '../code_providers.dart';
import '../domain/agent_mode.dart';
import '../domain/session_commands.dart';
import '../domain/transcript.dart';

/// Wires the Code session commands to session [sessionId]. Callbacks that
/// need the screen ([context]) check it is still mounted after each await.
CodeSlashHost codeSlashHost(BuildContext context, WidgetRef ref, String sessionId, {required bool busy}) {
  final provider = codeSessionProvider(sessionId);
  CodeSessionController controller() => ref.read(provider.notifier);
  void toast(String message) {
    if (context.mounted && message.isNotEmpty) showAdaptiveToast(context, message);
  }

  Future<void> switchTo({String? model, String? effort}) async {
    try {
      toast(await controller().switchModel(model: model, effort: effort));
    } on Object catch (e) {
      toast("Couldn't switch: $e");
    }
  }

  return CodeSlashHost(
    setMode: (name) => controller().setMode(AgentMode.values.byName(name)),
    stop: busy ? controller().stop : null,
    build: (args) async {
      final state = ref.read(provider);
      if (args.isNotEmpty) {
        await controller().setMode(AgentMode.autoEdit);
        await controller().send(args);
      } else if (state.mode == AgentMode.plan || state.transcript.openPlan != null) {
        await controller().startBuilding();
      } else {
        await controller().setMode(AgentMode.autoEdit);
        toast('Auto-edit mode: send what to build.');
      }
    },
    setModel: (query) {
      final choice = agentChoiceFor(query, ref.read(agentCatalogProvider).models);
      final spec = choice == null ? modelForQuery(ref.read(modelCatalogProvider), query) : null;
      if (choice == null && spec == null) return toast('No model matches "$query".');
      switchTo(model: choice?.model ?? spec!.id.value, effort: choice?.effort);
    },
    setEffort: (arg) {
      final effort = codeEffortArg(arg);
      if (effort == null) return toast('Pick one: low, medium, high, xhigh, max or default.');
      switchTo(effort: effort);
    },
    clear: (args) async {
      final sessions = ref.read(codeSessionsProvider.notifier);
      final info = sessions.byId(sessionId);
      final project = ref.read(codeProjectsProvider).where((p) => p.id == info?.projectId).firstOrNull;
      if (info == null || project == null || args.isEmpty) {
        if (context.mounted) context.go(Routes.code);
        return;
      }
      try {
        final next = await sessions.start(
          project: project,
          prompt: args,
          model: info.model,
          effort: info.effort.isEmpty ? null : info.effort,
          mode: ref.read(provider).mode,
        );
        if (context.mounted) context.go(Routes.codeSession(next.id));
      } on Object catch (e) {
        toast("Couldn't start the session: $e");
      }
    },
    compact: (focus) async {
      toast('Compacting the session…');
      final outcome = await controller().compact(focus: focus);
      toast(switch (outcome.kind) {
        CompactKind.compacted => 'Compacted: older turns are now a summary.',
        CompactKind.nothing => 'Nothing to compact yet.',
        CompactKind.busy => 'The agent is busy; compact when it stops.',
        CompactKind.failed => "Couldn't compact: ${outcome.message}",
      });
    },
    rewind: (args) async {
      final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
      if (info?.worktree == null) return toast('This session has no checkpoints (it is not in a git worktree).');
      final turns = ref.read(provider).transcript.items.whereType<UserTurn>().length;
      final turn = rewindTarget(turns, args);
      if (turn == null) return toast(turns == 0 ? 'Nothing to rewind yet.' : 'Give a number of turns: /rewind 2');
      final back = turns - turn + 1;
      final ok = await showAdaptiveConfirm(
        context,
        title: 'Restore files?',
        message:
            "Puts this session's files back to how they were before "
            "${back == 1 ? 'your last message' : 'your last $back messages'}. The conversation stays as it is.",
        confirmLabel: 'Restore',
        destructive: true,
      );
      if (!ok) return;
      try {
        await ref.read(codeGitProvider(sessionId).notifier).rewind(turn);
        toast('Files restored');
      } on Object catch (e) {
        toast("Couldn't restore: $e");
      }
    },
    cost: () => controller().showCost(),
    btw: (question) => controller().askAside(question),
  );
}
