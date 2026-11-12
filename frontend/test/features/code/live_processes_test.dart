@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:every_ai/core/process/supervisor.dart';
import 'package:every_ai/features/code/live/nested_display_io.dart';
import 'package:every_ai/features/code/live/supervised_stream_io.dart';
import 'package:every_ai/features/code/live/verified_download_io.dart';
import 'package:flutter_test/flutter_test.dart';

final nap = '33.$pid';

const fast = StopTimings(
  termGrace: Duration(milliseconds: 300),
  killWait: Duration(seconds: 2),
  poll: Duration(milliseconds: 25),
);

List<String> leftovers() => [
  for (final l in const LineSplitter().convert('${Process.runSync('ps', ['-A', '-o', 'pid=,stat=,command=']).stdout}'))
    if (l.contains('sleep $nap') && !l.contains(' Z')) l.trim(),
];

/// Passes bytes through as frames.
final class _Raw extends StreamTransformerBase<List<int>, Uint8List> {
  @override
  Stream<Uint8List> bind(Stream<List<int>> stream) => stream.map(Uint8List.fromList);
}

void main() {
  late Directory dir;
  final app = ProcessSupervisor.instance;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('live_processes');
    ProcessSupervisor.instance = ProcessSupervisor.create(
      ledgerDir: '${dir.path}/ledger',
      hooks: const SupervisorHooks(timings: fast),
    );
  });
  tearDown(() {
    ProcessSupervisor.instance = app;
    expect(leftovers(), isEmpty);
    dir.deleteSync(recursive: true);
  });

  Future<SupervisedProcess> napper() => ProcessSupervisor.instance.spawn(
    SpawnSpec(owner: const AppOwner(), kind: ProcessKind.stream, exe: 'sleep', args: [nap], label: 'nap'),
  );

  group('frame streams', () {
    test('a cancel while the helper starts: the helper that lands is stopped, nothing is left', () async {
      final gate = Completer<void>();
      final phases = <StreamPhase>[];
      final stream = supervisedFrames(
        'test stream',
        () async {
          await gate.future;
          return napper();
        },
        _Raw(),
        onPhase: phases.add,
      );
      final sub = stream.listen((_) {});
      await pumpEventQueue();
      expect(phases.last, isA<StreamSpawning>());
      final cancelled = sub.cancel();
      expect(phases.last, isA<StreamStopping>());
      gate.complete();
      await cancelled;
      expect(phases.last, isA<StreamStopped>().having((p) => p.outcome, 'outcome', isA<Ended>()));
      expect(ProcessSupervisor.instance.children, isEmpty);
    });

    test('a cancel while streaming stops the helper (checked)', () async {
      final phases = <StreamPhase>[];
      final sub = supervisedFrames('test stream', napper, _Raw(), onPhase: phases.add).listen((_) {});
      while (phases.last is! StreamStreaming) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(leftovers(), hasLength(1));
      await sub.cancel();
      expect(phases.last, isA<StreamStopped>().having((p) => p.outcome, 'outcome', isA<Ended>()));
    });
  });

  group('nested displays', () {
    tearDown(() {
      NestedDisplays.program = null;
      NestedDisplays.startTimeout = const Duration(seconds: 10);
    });

    File standIn(String body) {
      final f = File('${dir.path}/xvfb')..writeAsStringSync('#!/bin/sh\n$body\n');
      Process.runSync('chmod', ['+x', f.path]);
      return f;
    }

    test('an Xvfb that never says its display is stopped at the timeout', () async {
      NestedDisplays.program = standIn('exec sleep $nap').path;
      NestedDisplays.startTimeout = const Duration(milliseconds: 300);
      expect(await NestedDisplays.envFor('s1'), isEmpty);
      expect(ProcessSupervisor.instance.children, isEmpty);
    });

    test("a display is the session's child; its stop is checked, and one that dies by itself is dropped", () async {
      NestedDisplays.program = standIn('echo 7; exec sleep $nap').path;
      expect((await NestedDisplays.envFor('s2'))['DISPLAY'], ':7');
      expect(NestedDisplays.displayOf(['s2']), ':7');
      expect(ProcessSupervisor.instance.children.single.spec.owner, const SessionOwner('s2'));
      expect(await NestedDisplays.stopOf('s2'), isA<Ended>());
      expect(NestedDisplays.displayOf(['s2']), isNull);

      expect((await NestedDisplays.envFor('s3'))['DISPLAY'], ':7');
      final child = ProcessSupervisor.instance.children.single;
      Process.killPid(child.pid!, ProcessSignal.sigkill);
      await child.ended;
      await pumpEventQueue();
      expect(NestedDisplays.displayOf(['s3']), isNull);
    });
  });

  test('a download that stalls fails, leaves no file, and one target downloads once at a time', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var asked = 0;
    server.listen((req) {
      asked++;
      req.response
        ..contentLength = 1000
        ..add(List.filled(10, 1));
      // Never more: it stalls.
    });
    addTearDown(() => server.close(force: true));
    final url = Uri.parse('http://127.0.0.1:${server.port}/f');
    final part = File('${dir.path}/f.part');
    await expectLater(
      downloadVerified(url, 'x', part, idle: const Duration(milliseconds: 300)),
      throwsA(isA<TimeoutException>()),
    );
    expect(part.existsSync(), isFalse);

    final target = File('${dir.path}/t');
    final a = downloadVerifiedTo(url, 'x', target);
    final b = downloadVerifiedTo(url, 'x', target);
    expect(identical(a, b), isTrue);
    await server.close(force: true);
    await expectLater(a, throwsA(anything));
    expect(target.existsSync() || File('${target.path}.part').existsSync(), isFalse);
    expect(asked, greaterThanOrEqualTo(1));
  });
}
