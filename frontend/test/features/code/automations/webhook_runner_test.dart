import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/automations/schedule_providers.dart' show scheduleSessionActiveProvider;
import 'package:every_ai/features/code/automations/webhook.dart';
import 'package:every_ai/features/code/automations/webhook_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/session_notifications.dart' show SystemNotifier, systemNotifierProvider;
import 'package:every_ai/features/remote/data/host_link.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Notices implements SystemNotifier {
  final shown = <(String, String)>[];

  @override
  Future<void> show(String title, String body) async => shown.add((title, body));
}

WebhookDelivery _delivery(String id, {String hook = 'h1', String? event}) => WebhookDelivery(
  id: id,
  hookId: hook,
  hookName: 'CI',
  headers: {'x-github-event': ?event},
  body: Uint8List.fromList(utf8.encode('{"issue":{"title":"Crash"}}')),
  receivedAt: DateTime(2026, 11, 5, 9),
);

WebhookAutomation _auto({
  String hook = 'h1',
  AgentMode mode = AgentMode.autoEdit,
  bool confirmed = false,
  String event = '',
  bool enabled = true,
}) => WebhookAutomation(
  hookId: hook,
  name: 'New issues',
  url: 'https://api/v1/hooks/$hook',
  projectId: 'p',
  prompt: 'Triage {{json.issue.title}}',
  mode: mode,
  unattendedConfirmed: confirmed,
  event: event,
  enabled: enabled,
);

final class _Rig {
  _Rig(List<WebhookAutomation> stored) {
    prefs = Preferences.inMemory({
      'code.webhooks': jsonEncode([for (final a in stored) a.toJson()]),
    });
    container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        systemNotifierProvider.overrideWithValue(notices),
        scheduleSessionActiveProvider.overrideWithValue(active.contains),
        webhookStarterProvider.overrideWithValue((a, prompt) async {
          started.add((a, prompt));
          await hold;
          if (failWith != null) throw failWith!;
          return CodeSessionInfo(
            id: 's${started.length}',
            projectId: a.projectId,
            title: a.name,
            conversationId: 'c',
            model: 'm',
            mode: a.effectiveMode,
            workingDir: '/x',
            createdAt: DateTime(2026),
          );
        }),
      ],
    );
  }

  late final Preferences prefs;
  late final ProviderContainer container;
  final notices = _Notices();
  final started = <(WebhookAutomation, String)>[];
  final acked = <String>[];
  final active = <String>{};
  Future<void> hold = Future.value();
  Object? failWith;

  WebhookRunner get runner => container.read(webhookRunnerProvider.notifier);
  WebhookAutomation get only => container.read(webhookAutomationsProvider).single;

  Future<void> deliver(WebhookDelivery d) => runner.handle(d, acked.add);
}

void main() {
  test('a delivery starts one session in Auto-edit with the filled-in prompt, and is acked', () async {
    final rig = _Rig([_auto(mode: AgentMode.fullAuto)]);
    addTearDown(rig.container.dispose);
    await rig.deliver(_delivery('d1'));
    expect(rig.started, hasLength(1));
    final (a, prompt) = rig.started.single;
    // Full auto wasn't confirmed: it runs in Auto-edit.
    expect(a.effectiveMode, AgentMode.autoEdit);
    expect(prompt, startsWith('Triage <untrusted-content source="webhook New issues json.issue.title">\nCrash\n'));
    expect(rig.acked, ['d1']);
    expect(rig.only.lastSessionId, 's1');
    expect(rig.only.lastError, isNull);
    expect(rig.notices.shown.single.$1, 'Webhook started a session');
  });

  test('Full auto holds when it was confirmed', () async {
    final rig = _Rig([_auto(mode: AgentMode.fullAuto, confirmed: true)]);
    addTearDown(rig.container.dispose);
    await rig.deliver(_delivery('d1'));
    expect(rig.started.single.$1.effectiveMode, AgentMode.fullAuto);
  });

  test('a delivery seen before starts nothing, and is acked again', () async {
    final rig = _Rig([_auto()]);
    addTearDown(rig.container.dispose);
    await rig.deliver(_delivery('d1'));
    await rig.deliver(_delivery('d1'));
    expect(rig.started, hasLength(1));
    expect(rig.acked, ['d1', 'd1']);
    // Remembered across restarts (Preferences), and only the last 200.
    for (var i = 0; i < 205; i++) {
      await rig.deliver(_delivery('x$i', hook: 'nobody'));
    }
    final seen = jsonDecode(rig.prefs['code.webhook_seen']!) as List<Object?>;
    expect(seen, hasLength(WebhookRunner.seenLimit));
    expect(seen.last, 'x204');
  });

  test('off, another event, or the last run still going: skipped with a note, acked', () async {
    final off = _Rig([_auto(enabled: false)]);
    addTearDown(off.container.dispose);
    await off.deliver(_delivery('d1'));
    expect(off.started, isEmpty);
    expect(off.only.lastError, contains('turned off'));
    expect(off.acked, ['d1']);

    final filtered = _Rig([_auto(event: 'issues')]);
    addTearDown(filtered.container.dispose);
    await filtered.deliver(_delivery('d1', event: 'push'));
    expect(filtered.started, isEmpty);
    expect(filtered.only.lastError, 'Skipped a push: this webhook starts on issues.');
    await filtered.deliver(_delivery('d2', event: 'issues'));
    expect(filtered.started, hasLength(1));
    expect(filtered.acked, ['d1', 'd2']);

    final busy = _Rig([_auto()]);
    addTearDown(busy.container.dispose);
    await busy.deliver(_delivery('d1'));
    busy.active.add('s1');
    await busy.deliver(_delivery('d2'));
    expect(busy.started, hasLength(1));
    expect(busy.only.lastError, contains('still working'));
    expect(busy.acked, ['d1', 'd2']);
  });

  test('a second delivery while the first session is starting is skipped', () async {
    final rig = _Rig([_auto()]);
    addTearDown(rig.container.dispose);
    final gate = Completer<void>();
    rig.hold = gate.future;
    final first = rig.deliver(_delivery('d1'));
    await rig.deliver(_delivery('d2'));
    expect(rig.acked, ['d2']);
    gate.complete();
    await first;
    expect(rig.started, hasLength(1));
    expect(rig.acked, ['d2', 'd1']);
  });

  test('a start error is kept on the automation; an unknown hook is acked and ignored', () async {
    final rig = _Rig([_auto()]);
    addTearDown(rig.container.dispose);
    rig.failWith = StateError('The project is gone.');
    await rig.deliver(_delivery('d1'));
    expect(rig.only.lastError, contains('The project is gone.'));
    expect(rig.notices.shown.single.$1, "Webhook didn't start a session");
    expect(rig.acked, ['d1']);

    await rig.deliver(_delivery('d2', hook: 'elsewhere'));
    expect(rig.started, hasLength(1));
    expect(rig.acked, ['d1', 'd2']);
  });
}
