import 'dart:async';

import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/session_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Recorder implements SystemNotifier {
  final shown = <String>[];
  @override
  Future<void> show(String title, String body) async => shown.add(title);
}

void main() {
  group('StatusAlerts', () {
    late _Recorder recorder;
    late ProviderContainer container;
    late List<void Function()> timers;
    late List<void Function()> batches;
    late StatusAlerts alerts;
    var busy = false;

    StatusAlerts make(String title, {String? id}) => StatusAlerts(
      container.read(_ref),
      () => title,
      id: id,
      timer: (_, fire) {
        timers.add(fire);
        return _NoTimer();
      },
      busy: () => busy,
    );

    setUp(() {
      recorder = _Recorder();
      timers = [];
      batches = [];
      busy = false;
      container = ProviderContainer(
        overrides: [
          appFocusedProvider.overrideWithValue(() => false),
          systemNotifierProvider.overrideWithValue(recorder),
          notifyTimerProvider.overrideWithValue((_, fire) {
            batches.add(fire);
            return _NoTimer();
          }),
        ],
      );
      alerts = make('Fix the tests');
    });
    tearDown(() => container.dispose());

    test('a wait that lasts notifies once', () {
      alerts.onChange(SessionStatus.running, SessionStatus.needsInput);
      timers.single();
      expect(recorder.shown, ['Needs your input']);
    });

    test("a lead that finishes while its forks run isn't news until they end and settle, then once", () {
      busy = true;
      alerts.onChange(SessionStatus.running, SessionStatus.done);
      alerts.recheck();
      expect(timers, isEmpty);
      busy = false;
      alerts.recheck();
      alerts.recheck();
      // Released after [finishReleaseSettle], not at once: a report may still wake the lead.
      expect(batches, isEmpty);
      timers.single();
      batches.single();
      expect(recorder.shown, ['Finished']);
    });

    // The controller's order when the last fork reports: its side work ends (recheck) before the report is sent,
    // and the report then wakes the lead, whose own end is the real one.
    test('a report that wakes the lead makes one Finished, at the end of the turn it woke', () {
      var forks = true;
      var notices = 0;
      busy = false;
      final lead = StatusAlerts(
        container.read(_ref),
        () => 'Lead',
        timer: (_, fire) {
          timers.add(fire);
          return _NoTimer();
        },
        busy: () => forks || notices > 0,
        id: 'lead',
      );
      lead.onChange(SessionStatus.running, SessionStatus.done);
      // The fork ends; an outside lead's report waits in the queue: still busy.
      forks = false;
      notices = 1;
      lead.recheck();
      expect(timers, isEmpty);
      // The report goes; the work is over as far as the alerts can see, so the finish starts releasing.
      notices = 0;
      lead.recheck();
      expect(timers, hasLength(1));
      // The report wakes the lead before the release: the held finish is dropped.
      lead.onChange(SessionStatus.done, SessionStatus.running);
      timers.removeAt(0)();
      expect(batches, isEmpty);
      // That turn ends: Finished, once.
      lead.onChange(SessionStatus.running, SessionStatus.done);
      batches.single();
      expect(recorder.shown, ['Finished']);
    });

    test('running again drops a held finish', () {
      busy = true;
      alerts.onChange(SessionStatus.running, SessionStatus.done);
      alerts.onChange(SessionStatus.done, SessionStatus.running);
      busy = false;
      alerts.recheck();
      expect(timers, isEmpty);
      expect(batches, isEmpty);
    });

    test('sessions that finish together make one notification', () {
      alerts.onChange(SessionStatus.running, SessionStatus.done);
      make('Write docs').onChange(SessionStatus.running, SessionStatus.done);
      expect(batches, hasLength(1));
      batches.single();
      expect(recorder.shown, ['2 sessions finished']);
      expect(finishedNotice(['A', 'B']).body, 'A, B');
    });
  });
}

final _ref = Provider<Ref>((ref) => ref);

final class _NoTimer implements Timer {
  bool _active = true;
  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}
