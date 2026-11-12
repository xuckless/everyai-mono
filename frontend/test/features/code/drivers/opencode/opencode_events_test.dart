import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/drivers/driver_policy.dart';
import 'package:every_ai/features/code/drivers/opencode/opencode_driver.dart';
import 'package:every_ai/features/code/drivers/opencode/opencode_events.dart';
import 'package:every_ai/features/code/drivers/usage_limit.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

const _dir = 'test/fixtures/drivers/opencode';
const _ses = 'ses_e5adfc323ffe0y4ahZgv1t4ECA';
const _ses2 = 'ses_e5adcc5e9ffeq46VWxD6qlLA9d';
const _cwd = '/work/tree';

/// The recorded stream's frames of [session], in order.
List<Map<String, Object?>> _frames(String session) => [
  for (final l in File('$_dir/events.jsonl').readAsLinesSync())
    if (l.trim().isNotEmpty) jsonDecode(l) as Map<String, Object?>,
].where((f) => (f['data'] as Map?)?['sessionID'] == session).toList();

/// The frames of [session] from the first of [fromType] carrying [fromText]
/// up to (not including) the first of [toType] after it.
List<Map<String, Object?>> _slice(String session, bool Function(Map<String, Object?>) from, [String? toType]) {
  final all = _frames(session);
  final start = all.indexWhere(from);
  final end = toType == null ? all.length : all.indexWhere((f) => f['type'] == toType, start + 1);
  return all.sublist(start, end < 0 ? all.length : end + 1);
}

List<HarnessEvent> _play(OpenCodeMapper m, Iterable<Map<String, Object?>> frames) => [
  for (final f in frames) ...m.live(f),
];

bool _inbox(Map<String, Object?> f, String text) =>
    f['type'] == 'session.inbox.enqueued' && jsonEncode(f).contains(text);

void main() {
  test('parallel shell and write ask one at a time, each with the fields the rules read', () {
    final m = OpenCodeMapper(workingDir: _cwd);
    final frames = _slice(_ses, (f) => _inbox(f, 'Try again please.'), 'session.execution.succeeded');
    final upTo = frames.indexWhere((f) => f['type'] == 'permission.replied');
    final events = _play(m, frames.take(upTo));
    final calls = events.whereType<ActionCall>().toList();
    expect(calls.map((c) => c.actionKind), ['TerminalAction', 'FileEditorAction']);
    expect(calls[0].id, 'call_d2b65a794b2f4162a6062cd3');
    expect(calls[0].toolName, 'shell');
    expect(calls[0].str('command'), 'ls');
    expect(calls[1].str('command'), 'create');
    expect(calls[1].str('path'), '$_cwd/hello.txt');
    expect(calls.every(autoDecidable), isTrue);
    // Each call is followed by the wait for an answer.
    for (final c in calls) {
      final next = events[events.indexOf(c) + 1];
      expect(
        next,
        isA<StateChange>().having((s) => s.executionStatus, 'status', ExecutionStatus.waitingForConfirmation),
      );
    }
    expect(m.pending, {
      'call_d2b65a794b2f4162a6062cd3': 'per_1a520a36c001ForB4XXHoqUghI',
      'call_e25aab1c5deb4faba78eae1a': 'per_1a520a3d4001AAW2iyCpJXZM5w',
    });
    expect(events.first, isA<ChatMessage>().having((c) => c.fromUser, 'fromUser', true));
    expect(events.whereType<StreamDelta>().map((d) => d.content).join(), "I'll run both steps now.");
    expect(events.whereType<ChatMessage>().last.id, 'msg_1a52096a2001HQI5zNWP55ZKeg/text/0');

    final rest = _play(m, frames.skip(upTo));
    final results = rest.whereType<ToolResult>().toList();
    expect(results[0].actionId, 'call_d2b65a794b2f4162a6062cd3');
    expect(results[0].outcome, ToolOutcome.ok);
    expect(results[0].text, 'README.md\n');
    // Refused with a message: the model reads it and carries on.
    expect(results[1].actionId, 'call_e25aab1c5deb4faba78eae1a');
    expect(results[1].outcome, ToolOutcome.rejected);
    expect(results[1].observation['reason'], 'Not now: write it as hello.md instead.');
    expect(m.pending, isEmpty);
    expect(m.status, ExecutionStatus.finished);
    expect(rest.whereType<ChatMessage>().where((c) => c.reasoning.isNotEmpty), hasLength(1));
  });

  test('a step reports its usage with the cache counted in, and no cost when OpenCode says 0', () {
    // The driver's own rule: only providers signed in with a login are on a plan.
    final auth = openCodeAuth(jsonDecode(File('$_dir/auth_list.json').readAsStringSync()))!;
    expect(auth.oauth, {'anthropic'});
    final m = OpenCodeMapper(workingDir: _cwd, onPlan: auth.oauth.contains);
    final events = _play(m, _frames(_ses));
    final usage = events.whereType<UsageReport>().toList();
    final last = usage.firstWhere((u) => u.id == 'msg_1a520f12c001Q00sM7f4zqEI1P');
    expect(last.input, 324 + 9984);
    expect(last.cached, 9984);
    expect(last.output, 46);
    expect(last.contextTokens, 324 + 9984);
    expect(last.costMicros, isNull);
    // MiniMax's Token Plan is paid with a key: tokens show, with no cost and not as on a plan.
    expect(last.onPlan, isFalse);
    // Reasoning counts as output; an interrupted step still reports what it used.
    expect(usage.firstWhere((u) => u.id == 'msg_1a520c5e2001wntb199n7nT3U3').output, 39 + 196);
    expect(usage.map((u) => u.id), contains('msg_1a5215228001J63jOIWnmZ5XF6'));
    expect(usage.map((u) => u.id).toSet(), hasLength(usage.length));
    // The failed step had no tokens.
    expect(usage.map((u) => u.id), isNot(contains('msg_1a52059ea0014hQ15QKUcxo5l2')));
  });

  test('a call that asks twice gets a fresh id the second time, and refusing it all ends the run', () {
    final m = OpenCodeMapper(workingDir: _cwd);
    final frames = _frames(_ses2);
    final events = _play(m, frames);
    final calls = events.whereType<ActionCall>().toList();
    expect(calls.map((c) => c.id), [
      'call_7Jcm5k2wuV7zzQllFLKiWEmw',
      'call_7Jcm5k2wuV7zzQllFLKiWEmw#per_1a52367c5001HzfwaRgW5l3KDg',
    ]);
    // Outside the project: its own kind, so only the user answers it.
    expect(calls[0].actionKind, 'OpenCodeExternalDirectory');
    expect(calls[0].str('path'), '/etc/*');
    expect(autoDecidable(calls[0]), isFalse);
    expect(calls[1].actionKind, 'ReadFileAction');
    expect(calls[1].str('path'), '/etc/hosts');
    final results = events.whereType<ToolResult>().toList();
    expect(results.map((r) => r.actionId), [calls[0].id, calls[1].id]);
    expect(results[0].outcome, ToolOutcome.ok);
    // A bare refusal: OpenCode stops the call and the run.
    expect(results[1].outcome, ToolOutcome.rejected);
    expect(m.status, ExecutionStatus.idle);
    expect(m.pending, isEmpty);
  });

  test('a spent quota is a usage limit, dated only when live; a rate limit is a plain failure', () {
    final now = DateTime.utc(2026, 11, 4, 12);
    Map<String, Object?> failedRun(Map<String, Object?> error) => {
      'type': 'session.execution.failed',
      'data': {'sessionID': 's', 'error': error},
    };
    final live = OpenCodeMapper(workingDir: _cwd, now: () => now);
    live.live({
      'type': 'session.step.started',
      'data': {'sessionID': 's', 'assistantMessageID': 'msg_1'},
    });
    final quota = {'type': 'provider.quota', 'message': 'Quota exceeded for this plan.', 'retryAfterMs': 3600000};
    final limit = live.live(failedRun(quota)).map(usageLimitOf).nonNulls.single;
    expect(limit.message, 'Quota exceeded for this plan.');
    expect(limit.resetsAt, now.add(const Duration(hours: 1)));
    // The same run read back from history isn't shown twice.
    final messages = [
      {'id': 'msg_1', 'type': 'assistant', 'content': <Object?>[]},
      {'id': 'i1', 'type': 'idle', 'outcome': 'failed', 'error': quota},
    ];
    expect(live.history(messages).whereType<ConversationFailure>(), isEmpty);

    final reopened = OpenCodeMapper(workingDir: _cwd, now: () => now).history([
      {'id': 'msg_2', 'type': 'assistant', 'content': <Object?>[]},
      {
        'id': 'i2',
        'type': 'idle',
        'outcome': 'failed',
        'error': {'type': 'provider.free-limit', 'message': 'Free usage used up.', 'retryAfterMs': 60000},
      },
    ]);
    final free = reopened.map(usageLimitOf).nonNulls.single;
    expect((free.message, free.resetsAt), ('Free usage used up.', null));

    final rate = OpenCodeMapper(workingDir: _cwd)
        .live(failedRun({'type': 'provider.rate-limit', 'message': 'Rate limited.', 'retryAfterMs': 5000}));
    expect(rate.whereType<ConversationFailure>().single.message, 'Rate limited.');
    expect(rate.map(usageLimitOf).nonNulls, isEmpty);
  });

  test('history gives the same ids as the live stream, and nothing twice when both are read', () {
    final messages = (jsonDecode(File('$_dir/messages.json').readAsStringSync()) as Map)['data'] as List<Object?>;
    final fromHistory = OpenCodeMapper(workingDir: _cwd).history(messages);
    final live = OpenCodeMapper(workingDir: _cwd);
    final firstRun = _slice(_ses, (f) => f['type'] == 'session.inbox.enqueued', 'session.execution.succeeded');
    final fromLive = _play(live, firstRun);
    Iterable<String> ids(List<HarnessEvent> es) =>
        es.where((e) => e is! StateChange && e is! StreamDelta).map((e) => e.id);
    expect(ids(fromHistory).toSet(), ids(fromLive).toSet());
    expect(fromHistory.whereType<UsageReport>().map((u) => u.id), fromLive.whereType<UsageReport>().map((u) => u.id));
    expect(fromHistory.last, isA<StateChange>().having((s) => s.executionStatus, 'status', ExecutionStatus.finished));
    // A resync after the live run adds nothing, not even the state it already has.
    expect(live.history(messages, resync: true), isEmpty);
    final rejected = fromHistory.whereType<ToolResult>().firstWhere((r) => r.outcome == ToolOutcome.rejected);
    expect(rejected.actionId, 'call_e25aab1c5deb4faba78eae1a');
  });

  test('a web fetch runs on this machine, so only the user answers it', () {
    final m = OpenCodeMapper(workingDir: _cwd);
    m.live({
      'type': 'session.tool.input.started',
      'data': {'id': 'call_w', 'name': 'webfetch'},
    });
    m.live({
      'type': 'session.tool.called',
      'data': {
        'id': 'call_w',
        'input': {'url': 'http://169.254.169.254/latest/meta-data/'},
      },
    });
    final call = m
        .live({
          'type': 'permission.asked',
          'data': {
            'id': 'per_w',
            'action': 'webfetch',
            'resources': ['http://169.254.169.254/latest/meta-data/'],
            'source': {'type': 'tool', 'id': 'call_w'},
          },
        })
        .whereType<ActionCall>()
        .single;
    expect(call.actionKind, 'OpenCodeWebFetch');
    expect(autoDecidable(call), isFalse);
  });

  test('a shell request read without its input is judged on every sub-command', () {
    final m = OpenCodeMapper(workingDir: _cwd);
    final call = m
        .requests([
          {
            'id': 'per_s',
            'action': 'shell',
            'resources': ['ls', 'rm -rf build'],
            'source': {'type': 'tool', 'id': 'call_s'},
          },
        ])
        .whereType<ActionCall>()
        .single;
    expect(call.str('command'), 'ls && rm -rf build');
  });

  test('a run the history leaves going ends as interrupted when nothing runs it', () {
    final m = OpenCodeMapper(workingDir: _cwd);
    m.history([
      {
        'id': 'msg_u',
        'type': 'user',
        'text': 'hi',
        'time': {'created': 1},
      },
      {
        'id': 'msg_a',
        'type': 'assistant',
        'time': {'created': 2},
        'content': <Object?>[],
      },
    ]);
    expect(m.status, ExecutionStatus.running);
    expect(m.notRunning().single, isA<StateChange>().having((s) => s.executionStatus, 'status', ExecutionStatus.idle));
    expect(m.notRunning(), isEmpty);
  });
}
