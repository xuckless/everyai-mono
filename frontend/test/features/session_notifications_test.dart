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
}
