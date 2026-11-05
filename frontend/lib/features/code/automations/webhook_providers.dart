import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../../remote/data/host_link.dart' show WebhookDelivery;
import '../code_providers.dart' show codeSessionProvider;
import '../domain/code_session.dart';
import '../harness/harness.dart' show HarnessError;
import '../session_notifications.dart' show systemNotifierProvider;
import 'schedule_providers.dart';
import 'webhook.dart';

/// Starts the session for a delivery with the filled-in prompt. Tests replace it.
final webhookStarterProvider = Provider<Future<CodeSessionInfo> Function(WebhookAutomation, String prompt)>(
  (ref) =>
      (a, prompt) => startCodeTask(
        ref,
        projectId: a.projectId,
        title: a.name,
        prompt: prompt,
        harness: a.harness,
        model: a.model,
        effort: a.effort,
        mode: a.effectiveMode,
      ),
);

/// The webhook automations (Preferences `code.webhooks`), one per hook created on this computer.
final webhookAutomationsProvider = NotifierProvider<WebhookAutomations, List<WebhookAutomation>>(
  WebhookAutomations.new,
);

final class WebhookAutomations extends Notifier<List<WebhookAutomation>> {
  static const _key = 'code.webhooks';

  @override
  List<WebhookAutomation> build() {
    final raw = ref.read(preferencesProvider)[_key];
    if (raw == null) return const [];
    try {
      return [
        for (final j in jsonDecode(raw) as List<Object?>)
          if (j is Map<String, Object?>) ?_read(j),
      ];
    } on Object {
      return const [];
    }
  }

  static WebhookAutomation? _read(Map<String, Object?> j) {
    try {
      return WebhookAutomation.fromJson(j);
    } on Object {
      return null;
    }
  }

  void _save() => ref.read(preferencesProvider)[_key] = jsonEncode([for (final a in state) a.toJson()]);

  WebhookAutomation? byHook(String hookId) => state.where((a) => a.hookId == hookId).firstOrNull;

  /// Adds [a] or replaces the one for its hook, keeping the runner's last-delivery fields.
  void put(WebhookAutomation a) {
    final old = byHook(a.hookId);
    final kept = old == null
        ? a
        : a.copyWith(lastDeliveryAt: old.lastDeliveryAt, lastSessionId: old.lastSessionId, lastError: old.lastError);
    state = old == null ? [...state, kept] : [for (final x in state) x.hookId == a.hookId ? kept : x];
    _save();
  }

  void remove(String hookId) {
    state = [
      for (final a in state)
        if (a.hookId != hookId) a,
    ];
    _save();
  }

  void patch(String hookId, WebhookAutomation Function(WebhookAutomation) change) {
    state = [for (final a in state) a.hookId == hookId ? change(a) : a];
    _save();
  }
}

/// Whether a session a webhook started is still working (starting or running), so its hook's next delivery
/// waits for it. A session waiting for input doesn't hold the queue: nobody may be there to answer. Tests replace it.
final webhookSessionBusyProvider = Provider<bool Function(String)>(
  (ref) =>
      // A session nobody has open has no controller, and reading one here would build it just to ask.
      (id) =>
          ref.exists(codeSessionProvider(id)) &&
          switch (ref.read(codeSessionProvider(id)).status) {
            SessionStatus.starting || SessionStatus.running => true,
            _ => false,
          },
);

/// Turns webhook deliveries into Code sessions, one session per hook at a time. Its state is the hooks starting a
/// session right now.
final webhookRunnerProvider = NotifierProvider<WebhookRunner, Set<String>>(WebhookRunner.new);

final class WebhookRunner extends Notifier<Set<String>> {
  static const _seenKey = 'code.webhook_seen';

  /// Delivery ids remembered, so a delivery the relay sends again (no ack reached it) starts nothing twice.
  static const seenLimit = 200;

  /// Per hook, the deliveries waiting for its last session to finish, oldest first, each with its ack. They stay
  /// unacked meanwhile, so the backend keeps them (and sends them again after a reconnect) and holds back the
  /// ones behind them.
  final _waiting = <String, List<(WebhookDelivery, void Function(String))>>{};

  @override
  Set<String> build() {
    // Looks again for hooks whose session finished; no event says so.
    final every = ref.read(scheduleTickProvider);
    if (every != null) {
      final timer = Timer.periodic(every, (_) => unawaited(pump()));
      ref.onDispose(timer.cancel);
    }
    return const {};
  }

  List<String> _seen() {
    try {
      return [...(jsonDecode(ref.read(preferencesProvider)[_seenKey] ?? '[]') as List<Object?>).whereType<String>()];
    } on Object {
      return [];
    }
  }

  /// Remembered before anything starts: a crash between the start and the ack must not start it again.
  void _remember(String id) {
    final seen = _seen();
    ref.read(preferencesProvider)[_seenKey] = jsonEncode([
      ...seen.skip(seen.length >= seenLimit ? seen.length - seenLimit + 1 : 0),
      id,
    ]);
  }

  /// Queues [d] behind its hook's other deliveries and handles what can go now. [ack] is called once [d] is done
  /// with (started, skipped or failed), so the relay doesn't send it again; not while it waits its turn.
  Future<void> handle(WebhookDelivery d, void Function(String deliveryId) ack) async {
    if (_seen().contains(d.id)) return ack(d.id);
    final queue = _waiting.putIfAbsent(d.hookId, () => []);
    final i = queue.indexWhere((w) => w.$1.id == d.id);
    // Sent again while it waits (a reconnect): one entry, acked on the link that has it now.
    if (i >= 0) {
      queue[i] = (d, ack);
      return;
    }
    queue.add((d, ack));
    await _pump(d.hookId);
  }

  /// Handles the next deliveries of every hook whose last session is done. The timer calls it.
  Future<void> pump() async {
    for (final hookId in [..._waiting.keys]) {
      await _pump(hookId);
    }
  }

  Future<void> _pump(String hookId) async {
    final automations = ref.read(webhookAutomationsProvider.notifier);
    while (true) {
      final queue = _waiting[hookId];
      if (queue == null || queue.isEmpty) {
        _waiting.remove(hookId);
        return;
      }
      final (d, ack) = queue.first;
      final a = automations.byHook(hookId);
      final skip = a == null ? '' : _skipReason(a, d);
      if (skip == null) {
        // Its turn comes when the session before it is done.
        if (state.contains(hookId)) return;
        if (a!.lastSessionId case final sid? when ref.read(webhookSessionBusyProvider)(sid)) return;
      }
      queue.removeAt(0);
      _remember(d.id);
      try {
        if (skip == null) {
          await _start(a!, d);
        } else if (skip.isNotEmpty) {
          automations.patch(hookId, (x) => x.copyWith(lastDeliveryAt: d.receivedAt, lastError: skip));
        }
      } finally {
        ack(d.id);
      }
    }
  }

  /// Why [d] starts nothing (a note for the automation), or null when it starts a session. '' for a hook made on
  /// another computer, or one whose automation was removed here: nothing to note.
  static String? _skipReason(WebhookAutomation a, WebhookDelivery d) {
    if (!a.enabled) return 'Skipped a delivery: this webhook is turned off.';
    if (a.event.isNotEmpty && d.event != a.event) {
      return 'Skipped a ${d.event ?? 'delivery without an event name'}: this webhook starts on ${a.event}.';
    }
    return null;
  }

  Future<void> _start(WebhookAutomation a, WebhookDelivery d) async {
    final automations = ref.read(webhookAutomationsProvider.notifier);
    state = {...state, a.hookId};
    final notify = ref.read(systemNotifierProvider);
    try {
      final info = await ref.read(webhookStarterProvider)(a, webhookPrompt(a.prompt, d, name: a.name));
      automations.patch(
        a.hookId,
        (x) => x.copyWith(lastDeliveryAt: d.receivedAt, lastSessionId: info.id, lastError: null),
      );
      unawaited(notify.show('Webhook started a session', a.name));
    } on Object catch (e) {
      final why = e is HarnessError ? e.message : '$e';
      automations.patch(a.hookId, (x) => x.copyWith(lastDeliveryAt: d.receivedAt, lastError: why));
      unawaited(notify.show("Webhook didn't start a session", '${a.name}: $why'));
    } finally {
      state = {...state}..remove(a.hookId);
    }
  }
}
