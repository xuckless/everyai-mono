import 'dart:async';

import 'package:every_ai/features/local_models/data/ollama_pull.dart';
import 'package:every_ai/features/local_models/local_models_providers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  test('a stream that ends without success is a failure', () async {
    final http = FakeLocalHttp()..pullLines['x'] = ['{"status":"pulling manifest"}'];
    final states = await pullModel(http, defaultOllamaRoot, 'x').toList();
    expect(states.last.phase, DownloadPhase.failed);
  });

  test('a pull that goes quiet fails as stalled and ends its request', () async {
    final http = FakeLocalHttp();
    final states = <DownloadState>[];
    final done = Completer<void>();
    pullModel(
      http,
      defaultOllamaRoot,
      'q',
      stallAfter: const Duration(milliseconds: 80),
    ).listen(states.add, onDone: done.complete);
    await pumpEventQueue();
    http.pulls['q']!.add('{"status":"pulling abc","total":10,"completed":1}');
    await done.future.timeout(const Duration(seconds: 2));
    expect(states.last.phase, DownloadPhase.failed);
    expect(states.last.error, startsWith('stalled'));
    expect(http.pulls['q']!.hasListener, isFalse);
  });

  test('Ollama verifying a big layer in silence is not a stall', () async {
    final http = FakeLocalHttp();
    final states = <DownloadState>[];
    final done = Completer<void>();
    pullModel(
      http,
      defaultOllamaRoot,
      'v',
      stallAfter: const Duration(milliseconds: 60),
      quietStallAfter: const Duration(milliseconds: 600),
    ).listen(states.add, onDone: done.complete);
    await pumpEventQueue();
    http.pulls['v']!.add('{"status":"verifying sha256 digest"}');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(done.isCompleted, isFalse);
    http.pulls['v']!.add('{"status":"success"}');
    await done.future.timeout(const Duration(seconds: 2));
    expect(states.last.phase, DownloadPhase.done);
  });
}
