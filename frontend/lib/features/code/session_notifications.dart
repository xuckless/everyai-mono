import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/process/supervisor.dart';
import 'drivers/short_run.dart';

import 'domain/code_session.dart';
import 'domain/transcript.dart' show AlertSeverity, SecurityAlert;

/// What deserves an OS notification when a session goes from [from] to [to]:
/// it started waiting for the user, or it finished what it was doing.
/// Null for every other change (and for a first sighting, [from] null).
({String title, String body})? notificationFor(SessionStatus? from, SessionStatus to, String session) {
  if (from == null || from == to) return null;
  if (to == SessionStatus.needsInput) return (title: 'Needs your input', body: session);
  if (to == SessionStatus.done && (from == SessionStatus.running || from == SessionStatus.starting)) {
    return (title: 'Finished', body: session);
  }
  if (to == SessionStatus.failed && from == SessionStatus.running) return (title: 'Stopped on an error', body: session);
  return null;
}

/// Shows a notification outside the app.
abstract interface class SystemNotifier {
  Future<void> show(String title, String body);
}

/// Native commands (`osascript` on macOS, `notify-send` on Linux); other
/// platforms show nothing.
final class CommandNotifier implements SystemNotifier {
  const CommandNotifier();

  @override
  Future<void> show(String title, String body) async {
    final RunResult r;
    if (Platform.isMacOS) {
      String q(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
      r = await runShort(
        'osascript',
        ['-e', 'display notification ${q(body)} with title ${q('EveryAI')} subtitle ${q(title)}'],
        timeout: notifyTimeout,
        owner: const ProbeOwner('notify'),
      );
    } else if (Platform.isLinux) {
      // Notification servers may read the body (not the title) as markup: quoted page text must not become a link.
      r = await runShort(
        'notify-send',
        ['--app-name=EveryAI', title, notifyPlain(body)],
        timeout: notifyTimeout,
        owner: const ProbeOwner('notify'),
      );
    } else {
      return;
    }
    // No notification service (the status dot still shows it), or one that hung (stopped, verified): in the log.
    switch (r) {
      case TimedOut(:final kill) || Cancelled(:final kill):
        logStop('notification', kill);
        debugPrint('EveryAI notifications: ${runProblem('notification', r)}');
      case Finished() || StartFailed():
        break;
    }
  }

  /// How long a notification command may take (osascript asks for permission the first time).
  static const notifyTimeout = Duration(seconds: 15);
}

/// [s] with the characters notification markup reads escaped, so it shows as written.
String notifyPlain(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

final systemNotifierProvider = Provider<SystemNotifier>((ref) => const CommandNotifier());

/// Asks whether the app is in front, at the moment of asking (a cached
/// answer would hold for the life of the app); tests replace it.
final appFocusedProvider = Provider<bool Function()>((ref) => _appInFront);

bool _appInFront() {
  try {
    return WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    // No binding (a headless test): there is no window to be behind.
    // ignore: avoid_catching_errors
  } on Error {
    return true;
  }
}

/// Notifies about a status change of [session] unless the app is in front
/// (then the status pill and the session list already show it). Finishes go
/// through [finishBatchProvider], so several at once make one notification.
/// [id] tells sessions with the same title apart in a batch (the title when null).
void notifyStatusChange(Ref ref, SessionStatus? from, SessionStatus to, String session, {String? id}) {
  final n = notificationFor(from, to, session);
  if (n == null || ref.read(appFocusedProvider)()) return;
  if (to == SessionStatus.done) return ref.read(finishBatchProvider).add(id ?? session, session);
  unawaited(ref.read(systemNotifierProvider).show(n.title, n.body));
}

/// Starts the timers notifications wait on; tests replace it.
final notifyTimerProvider = Provider<Timer Function(Duration, void Function())>((ref) => Timer.new);

/// Finishes this close together go out as one notification.
const finishBatchWindow = Duration(seconds: 2);

/// The notification for sessions [names] that finished together.
({String title, String body}) finishedNotice(List<String> names) => names.length == 1
    ? (title: 'Finished', body: names.single)
    : (title: '${names.length} sessions finished', body: names.join(', '));

final finishBatchProvider = Provider<FinishBatch>((ref) {
  final batch = FinishBatch(ref);
  ref.onDispose(batch.dispose);
  return batch;
});

/// Collects finished sessions for [finishBatchWindow], then sends one notification for all of them:
///
/// ```text
///   empty ──add──► collecting ──window ends──► empty (one notification)
/// ```
final class FinishBatch {
  FinishBatch(this._ref);

  final Ref _ref;

  /// Session id → its title, in the order they finished (two sessions may share a title).
  final _names = <String, String>{};
  Timer? _timer;

  void add(String id, String title) {
    _names.putIfAbsent(id, () => title);
    _timer ??= _ref.read(notifyTimerProvider)(finishBatchWindow, _flush);
  }

  void _flush() {
    _timer = null;
    final names = [..._names.values];
    _names.clear();
    if (names.isEmpty || _ref.read(appFocusedProvider)()) return;
    final n = finishedNotice(names);
    unawaited(_ref.read(systemNotifierProvider).show(n.title, n.body));
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _names.clear();
  }
}

/// The notification for a security alert the agent of [session] raised.
({String title, String body}) securityNotification(SecurityAlert alert, String session) => (
  title: switch (alert.severity) {
    AlertSeverity.critical => 'Security alert: act now',
    AlertSeverity.warning => 'Security alert',
    AlertSeverity.info => 'Security note',
  },
  body: '$session: ${alert.what}${alert.stopRun ? ' The run stopped and waits for you.' : ''}',
);

/// Notifies about [alert], from any session (a subagent's or fork's too:
/// its transcript is off screen). A critical one goes out even with the app
/// in front; the others only when it is behind, like status changes.
void notifySecurityAlert(Ref ref, SecurityAlert alert, String session) {
  if (alert.severity != AlertSeverity.critical && ref.read(appFocusedProvider)()) return;
  final n = securityNotification(alert, session);
  unawaited(ref.read(systemNotifierProvider).show(n.title, n.body));
}

/// How long a session has to keep waiting before "Needs your input" goes out.
/// An approval the mode answers by itself (Auto-edit, Full auto) passes
/// through needsInput for a moment on every step; those blips aren't news.
const needsInputSettle = Duration(seconds: 3);

/// How long a finish held for the session's own work waits after that work ends before it goes out: a fork's or
/// workflow's report usually wakes the lead, and that turn's own end is the real one.
const finishReleaseSettle = Duration(seconds: 3);

/// Where a session's notifications stand ([StatusAlerts]):
///
/// ```text
///   quiet ──needsInput──► settling ──lasts needsInputSettle──► quiet (Needs your input)
///     ▲                      └──any other change (a blip)──► quiet; the change reads as from before the wait
///     ├──done while its work runs──► held ──work ends (recheck)──► releasing
///     │                                ▲                              │
///     │                                └───── work runs again ────────┤
///     └─── a status change (runs again, waits on the user), or releasing ends: Finished ───┘
/// ```
/// A held or releasing finish is dropped when the session's status changes: running again (a report woke the lead,
/// and that turn's end notifies) or waiting on the user (the wait is the news; a later end notifies again).
sealed class _AlertState {
  const _AlertState();
}

final class _Quiet extends _AlertState {
  const _Quiet();
}

/// A wait on the user that may still be a blip; [before] is the status before it, so running → blip → done still
/// reads as "Finished".
final class _Settling extends _AlertState {
  _Settling(this.before);
  final SessionStatus? before;
  late final Timer timer;
}

/// A finish held while the session's work runs; [from] is the status it finished from.
final class _Held extends _AlertState {
  const _Held(this.from);
  final SessionStatus? from;
}

/// The work ended: the finish goes out when [timer] fires, unless the session changes first.
final class _Releasing extends _AlertState {
  _Releasing(this.from);
  final SessionStatus? from;
  late final Timer timer;
}

/// One session's notifications, with waits that end within [needsInputSettle] left out. Feed it every status change;
/// dispose it with the session.
///
/// A finish while the session's own work still runs ([busy]: its forks, subagents and workflows, and their reports
/// on the way to the lead) is held until that work ends ([recheck]), then for [finishReleaseSettle] more: the
/// notification comes at the real end, once.
final class StatusAlerts {
  StatusAlerts(
    this._ref,
    this._title, {
    Timer Function(Duration, void Function())? timer,
    bool Function()? busy,
    this.id,
  }) : _startTimer = timer ?? Timer.new,
       _busy = busy ?? _never;

  static bool _never() => false;

  final Ref _ref;
  final String Function() _title;
  final Timer Function(Duration, void Function()) _startTimer;
  final bool Function() _busy;

  /// The session's id, so [FinishBatch] tells sessions with the same title apart.
  final String? id;

  _AlertState _state = const _Quiet();

  void _notify(SessionStatus? from, SessionStatus to) => notifyStatusChange(_ref, from, to, _title(), id: id);

  void _cancelTimer() {
    switch (_state) {
      case _Settling(:final timer):
        timer.cancel();
      case _Releasing(:final timer):
        timer.cancel();
      case _Quiet() || _Held():
        break;
    }
  }

  void onChange(SessionStatus? from, SessionStatus to) {
    if (from == to) return;
    if (to == SessionStatus.needsInput) {
      // A first sighting (reopened while waiting) isn't news either.
      if (from == null) return;
      _cancelTimer();
      final settling = _Settling(from);
      _state = settling;
      settling.timer = _startTimer(needsInputSettle, () {
        if (!identical(_state, settling)) return;
        _state = const _Quiet();
        _notify(settling.before, SessionStatus.needsInput);
      });
      return;
    }
    var since = from;
    // The wait ended before anyone was told: as if it never happened.
    if (_state case _Settling(:final before) when from == SessionStatus.needsInput) since = before;
    _cancelTimer();
    _state = const _Quiet();
    if (to == SessionStatus.done && notificationFor(since, to, '') != null && _busy()) {
      _state = _Held(since);
      return;
    }
    _notify(since, to);
  }

  /// The session's work changed: a held finish starts releasing once nothing runs, and is held again when work
  /// starts before it went out.
  void recheck() {
    switch (_state) {
      case _Held(:final from) when !_busy():
        final releasing = _Releasing(from);
        _state = releasing;
        releasing.timer = _startTimer(finishReleaseSettle, () {
          if (!identical(_state, releasing)) return;
          if (_busy()) {
            _state = _Held(releasing.from);
            return;
          }
          _state = const _Quiet();
          _notify(releasing.from, SessionStatus.done);
        });
      case _Releasing(:final from, :final timer) when _busy():
        timer.cancel();
        _state = _Held(from);
      case _Quiet() || _Settling() || _Held() || _Releasing():
        break;
    }
  }

  void dispose() {
    _cancelTimer();
    _state = const _Quiet();
  }
}
