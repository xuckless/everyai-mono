import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../../remote/data/host_link.dart' show WebhookDelivery;
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

/// Turns webhook deliveries into Code sessions. Its state is the hooks starting a session right now.
final webhookRunnerProvider = NotifierProvider<WebhookRunner, Set<String>>(WebhookRunner.new);

final class WebhookRunner extends Notifier<Set<String>> {
  static const _seenKey = 'code.webhook_seen';

  /// Delivery ids remembered, so a delivery the relay sends again (no ack reached it) starts nothing twice.
  static const seenLimit = 200;

  @override
  Set<String> build() => const {};

  List<String> _seen() {
    try {
      return [...(jsonDecode(ref.read(preferencesProvider)[_seenKey] ?? '[]') as List<Object?>).whereType<String>()];
    } on Object {
      return [];
    }
  }

  /// Handles [d] and then calls [ack] whatever happened, so the relay doesn't send it again.
  Future<void> handle(WebhookDelivery d, void Function(String deliveryId) ack) async {
    try {
      await _handle(d);
    } finally {
      ack(d.id);
    }
  }

  Future<void> _handle(WebhookDelivery d) async {
    final seen = _seen();
    if (seen.contains(d.id)) return;
    // Remembered before anything starts: a crash between the start and the ack must not start it again.
    final prefs = ref.read(preferencesProvider);
    prefs[_seenKey] = jsonEncode([...seen.skip(seen.length >= seenLimit ? seen.length - seenLimit + 1 : 0), d.id]);

    final automations = ref.read(webhookAutomationsProvider.notifier);
    final a = automations.byHook(d.hookId);
    // A hook made on another computer, or one whose automation was removed here.
    if (a == null) return;
    void note(String why) =>
        automations.patch(a.hookId, (x) => x.copyWith(lastDeliveryAt: d.receivedAt, lastError: why));
    if (!a.enabled) return note('Skipped a delivery: this webhook is turned off.');
    if (a.event.isNotEmpty && d.event != a.event) {
      return note('Skipped a ${d.event ?? 'delivery without an event name'}: this webhook starts on ${a.event}.');
    }
    if (state.contains(a.hookId) ||
        (a.lastSessionId != null && ref.read(scheduleSessionActiveProvider)(a.lastSessionId!))) {
      return note('Skipped a delivery: the last session it started is still working.');
    }
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
      note(why);
      unawaited(notify.show("Webhook didn't start a session", '${a.name}: $why'));
    } finally {
      state = {...state}..remove(a.hookId);
    }
  }
}
