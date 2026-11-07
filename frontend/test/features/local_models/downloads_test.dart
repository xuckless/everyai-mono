import 'dart:async';

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/local_models/data/ollama_pull.dart';
import 'package:every_ai/features/local_models/local_models_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  test('pull lines: layers with bytes, success, and an error', () {
    var s = const DownloadState(tag: 'qwen3.5:4b', phase: DownloadPhase.running);
    s = applyPullLine(s, '{"status":"pulling manifest"}');
    expect((s.status, s.fraction), ('pulling manifest', null));
    s = applyPullLine(s, '{"status":"pulling abc","digest":"sha256:abc","total":1000,"completed":250}');
    expect(s.fraction, 0.25);
    s = applyPullLine(s, 'not json');
    expect(s.fraction, 0.25);
    expect(applyPullLine(s, '{"status":"success"}').phase, DownloadPhase.done);
    final failed = applyPullLine(s, '{"error":"pull model manifest: file does not exist"}');
    expect((failed.phase, failed.error), (DownloadPhase.failed, 'pull model manifest: file does not exist'));
  });

  test('a stream that ends without success is a failure', () async {
    final http = FakeLocalHttp()..pullLines['x'] = ['{"status":"pulling manifest"}'];
    final states = await pullModel(http, defaultOllamaRoot, 'x').toList();
    expect(states.last.phase, DownloadPhase.failed);
  });

  test('downloads run one at a time; cancel moves on; delete calls Ollama', () async {
    final http = FakeLocalHttp({'DELETE 127.0.0.1:11434/api/delete': json('{}')});
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(Preferences.inMemory()),
        localHttpProvider.overrideWithValue(http),
        localSystemProvider.overrideWithValue(FakeLocalSystem()),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(downloadsProvider, (_, _) {});
    addTearDown(sub.close);
    final downloads = c.read(downloadsProvider.notifier);
    downloads.enqueue(['a', 'b']);
    await pumpEventQueue();
    expect(http.calls.where((k) => k.startsWith('PULL')), ['PULL a']);
    expect(c.read(downloadsProvider)['b']!.phase, DownloadPhase.queued);

    http.pulls['a']!.add('{"status":"pulling x","total":10,"completed":5}');
    await pumpEventQueue();
    expect(c.read(downloadsProvider)['a']!.fraction, 0.5);

    downloads.cancel('a');
    await pumpEventQueue();
    expect(c.read(downloadsProvider)['a']!.phase, DownloadPhase.cancelled);
    expect(http.calls.where((k) => k.startsWith('PULL')), ['PULL a', 'PULL b']);

    http.pulls['b']!.add('{"status":"success"}');
    await pumpEventQueue();
    expect(c.read(downloadsProvider)['b']!.phase, DownloadPhase.done);

    // Queuing a done one again is a no-op; a cancelled one resumes.
    downloads.enqueue(['b', 'a']);
    await pumpEventQueue();
    expect(http.calls.where((k) => k.startsWith('PULL')), ['PULL a', 'PULL b', 'PULL a']);

    expect(await downloads.delete('b'), isNull);
    expect(http.sent['DELETE 127.0.0.1:11434/api/delete'], {'model': 'b'});
    expect(c.read(downloadsProvider).containsKey('b'), isFalse);
    unawaited(http.pulls['a']!.close());
  });
}
