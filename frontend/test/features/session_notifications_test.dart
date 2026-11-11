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

final _notify = Provider.family<void, (SessionStatus, SessionStatus)>(
  (ref, change) => notifyStatusChange(ref, change.$1, change.$2, 'Fix the tests'),
);

void main() {
  test('asks whether the app is in front at every change, not once', () {
    var focused = true;
    final recorder = _Recorder();
    final container = ProviderContainer(
      overrides: [
        appFocusedProvider.overrideWithValue(() => focused),
        systemNotifierProvider.overrideWithValue(recorder),
      ],
    );
    addTearDown(container.dispose);
    container.read(_notify((SessionStatus.running, SessionStatus.done)));
    expect(recorder.shown, isEmpty);
    focused = false;
    container.read(_notify((SessionStatus.running, SessionStatus.needsInput)));
    expect(recorder.shown, ['Needs your input']);
  });

  group('StatusAlerts', () {
    late _Recorder recorder;
    late ProviderContainer container;
    late List<void Function()> timers;
    late List<void Function()> batches;
    late StatusAlerts alerts;
    var busy = false;

    StatusAlerts make(String title) => StatusAlerts(
      container.read(_ref),
      () => title,
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

    test('an approval the mode answers at once (a blip) notifies nothing', () {
      for (var i = 0; i < 5; i++) {
        alerts.onChange(SessionStatus.running, SessionStatus.needsInput);
        alerts.onChange(SessionStatus.needsInput, SessionStatus.running);
      }
      expect(recorder.shown, isEmpty);
    });

    test('a wait that lasts notifies once', () {
      alerts.onChange(SessionStatus.running, SessionStatus.needsInput);
      timers.single();
      expect(recorder.shown, ['Needs your input']);
    });

    test('a blip right before the end still reads as finished', () {
      alerts.onChange(SessionStatus.running, SessionStatus.needsInput);
      alerts.onChange(SessionStatus.needsInput, SessionStatus.done);
      batches.single();
      expect(recorder.shown, ['Finished']);
    });

    test("a lead that finishes while its forks run isn't news until they end, then once", () {
      busy = true;
      alerts.onChange(SessionStatus.running, SessionStatus.done);
      alerts.recheck();
      expect(batches, isEmpty);
      busy = false;
      alerts.recheck();
      alerts.recheck();
      batches.single();
      expect(recorder.shown, ['Finished']);
    });

    test('running again drops a held finish', () {
      busy = true;
      alerts.onChange(SessionStatus.running, SessionStatus.done);
      alerts.onChange(SessionStatus.done, SessionStatus.running);
      busy = false;
      alerts.recheck();
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

    test('a session reopened already waiting is not news', () {
      alerts.onChange(null, SessionStatus.needsInput);
      expect(timers, isEmpty);
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
