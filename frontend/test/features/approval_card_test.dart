import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/native_approvals.dart';
import 'package:every_ai/features/code/domain/permissions.dart';
import 'package:every_ai/features/code/harness/harness.dart' show NativeRemember;
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/ui/transcript/approval_card.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  ActionCall bash(String id, String command) => HarnessEvent.decode({
    'kind': 'ActionEvent',
    'id': id,
    'tool_name': 'bash',
    'action': {'kind': 'TerminalAction', 'command': command},
  }) as ActionCall;

  final calls = [bash('a', 'npm test'), bash('b', 'rm -rf build')];

  Widget host({
    required void Function(String, ApprovalScope) onAllowCall,
    required void Function(String) onDenyCall,
    void Function(ApprovalScope)? onAllow,
    Map<String, bool> decided = const {},
    List<ActionCall>? pending,
    Map<String, String> reasons = const {},
    Map<String, String> flags = const {},
    List<String>? remember,
    bool forks = false,
    List<NativeAllowScope>? native,
  }) => m.MaterialApp(
    home: m.Material(
      child: EveryThemeScope(
        theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
        child: SingleChildScrollView(
          child: ApprovalCard(
            pending: pending ?? calls,
            mode: AgentMode.ask,
            reasons: reasons,
            flags: flags,
            remember: remember,
            forks: forks,
            onAllow: onAllow ?? (_) {},
            onDeny: (_) {},
            onMode: (_) {},
            onAllowCall: onAllowCall,
            onDenyCall: onDenyCall,
            decided: decided,
            rememberBy: const {'a': 'Bash(npm test)'},
            native: native,
          ),
        ),
      ),
    ),
  );

  testWidgets('several calls get a row each with their own answer, plus Allow all', (tester) async {
    final allowed = <String>[];
    final denied = <String>[];
    ApprovalScope? all;
    await tester.pumpWidget(
      host(onAllowCall: (id, _) => allowed.add(id), onDenyCall: denied.add, onAllow: (s) => all = s),
    );
    expect(find.text('Allow 2 actions?'), findsOneWidget);
    expect(find.text('Allow'), findsNWidgets(2));
    // Both are commands, so both offer "all commands for this session" under More.
    expect(find.text('More'), findsNWidgets(2));

    await tester.tap(find.text('Deny').last);
    await tester.tap(find.text('Allow').first);
    expect(allowed, ['a']);
    expect(denied, ['b']);

    await tester.tap(find.text('Allow all  ${Host.enterKeys(command: true)}'));
    expect(all, ApprovalScope.always, reason: 'asked once, saved for good');
  });

  testWidgets("an outside lead's card: Allow answers once, its CLI's own scopes only, no EveryAI rule", (tester) async {
    final scopes = <ApprovalScope>[];
    await tester.pumpWidget(
      host(
        pending: [calls.first],
        remember: const ['Bash(npm test)'],
        native: nativeAllowScopes(NativeRemember.session, 'Codex'),
        onAllow: scopes.add,
        onAllowCall: (_, _) {},
        onDenyCall: (_) {},
      ),
    );
    expect(find.textContaining('Allow similar'), findsNothing);
    expect(find.textContaining('Allow saves'), findsNothing);
    expect(find.textContaining('all commands'), findsNothing);
    await tester.tap(find.text('Allow for this session'));
    await tester.tap(find.text('Allow  ${Host.enterKeys(command: true)}'));
    expect(scopes, [ApprovalScope.session, ApprovalScope.once]);
  });

  testWidgets('answered rows are settled', (tester) async {
    await tester.pumpWidget(host(onAllowCall: (_, _) {}, onDenyCall: (_) {}, decided: const {'a': true}));
    expect(find.text('Allowed'), findsOneWidget);
    expect(find.text('1 of 2 actions still to answer'), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);
  });

  testWidgets('a call says why it asks; a dangerous one keeps its warning instead', (tester) async {
    await tester.pumpWidget(
      host(
        onAllowCall: (_, _) {},
        onDenyCall: (_) {},
        reasons: const {'a': 'Ask mode asks before every edit and command.', 'b': 'This deletes files recursively.'},
        flags: const {'b': 'deletes files recursively'},
      ),
    );
    expect(find.text('Asks because: Ask mode asks before every edit and command.'), findsOneWidget);
    expect(find.textContaining('Asks because: This deletes'), findsNothing);
    expect(find.text('Needs a look: this deletes files recursively'), findsOneWidget);
  });

  testWidgets("a fork's card offers to allow for all forks of the session", (tester) async {
    ApprovalScope? scope;
    await tester.pumpWidget(
      host(
        onAllowCall: (_, _) {},
        onDenyCall: (_) {},
        onAllow: (s) => scope = s,
        pending: [calls.first],
        remember: const ['npm test *'],
        forks: true,
      ),
    );
    expect(find.text('Allow for session'), findsNothing);
    await tester.tap(find.text('Allow similar for all forks of this session'));
    expect(scope, ApprovalScope.session);
  });
}
