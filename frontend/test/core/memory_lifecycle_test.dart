// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:every_ai/core/process/child_processes.dart';
import 'package:every_ai/core/process/supervisor.dart';
import 'package:every_ai/core/ui/image_decode.dart';
import 'package:every_ai/core/ui/syntax_spans.dart';
import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/harness/everyai/everyai_harness_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  // Each test gets a supervisor of its own (no watchdog, its ledger in a temp folder); the shim reads `instance`.
  final appSupervisor = ProcessSupervisor.instance;
  tearDown(() => ProcessSupervisor.instance = appSupervisor);

  group('child processes', () {
    test('the phase table: running → stopping → exited; nothing after exited', () {
      expect(nextChildPhase(ChildPhase.running, ChildEvent.stop), ChildPhase.stopping);
      expect(nextChildPhase(ChildPhase.running, ChildEvent.exited), ChildPhase.exited);
      expect(nextChildPhase(ChildPhase.stopping, ChildEvent.exited), ChildPhase.exited);
      expect(nextChildPhase(ChildPhase.stopping, ChildEvent.stop), isNull);
      for (final e in ChildEvent.values) {
        expect(nextChildPhase(ChildPhase.exited, e), isNull);
      }
    });

    test('a child is tracked until it exits; two stops kill once; stopAll ends the rest', () async {
      final dir = Directory.systemTemp.createTempSync('shim');
      addTearDown(() => dir.deleteSync(recursive: true));
      final exits = {
        for (final pid in [101, 102, 103]) pid: Completer<int>(),
      };
      final alive = {101, 102, 103};
      final killed = <int>[];
      ProcessSupervisor.instance = ProcessSupervisor.create(
        ledgerDir: dir.path,
        hooks: SupervisorHooks(
          timings: const StopTimings(termGrace: Duration(milliseconds: 50), poll: Duration(milliseconds: 5)),
          scan: ({required env}) async => Listed(
            ProcessList([
              for (final p in alive) ScanRow(pid: p, ppid: 1, pgid: 1, start: 's$p', command: '/bin/p'),
              ScanRow(pid: pid, ppid: 1, pgid: pid, start: 'me', command: 'test'),
            ]),
          ),
          signal: (p, s) {
            if (s == ProcessSignal.sigterm && alive.remove(p)) {
              killed.add(p);
              exits[p]!.complete(-15);
            }
            return true;
          },
        ),
      );
      for (final e in exits.entries) {
        ChildProcesses.track(e.key, label: 'p${e.key}', executable: '/bin/p', exited: e.value.future);
      }
      expect(ChildProcesses.tracked.keys, [101, 102, 103]);

      alive.remove(101);
      exits[101]!.complete(0);
      await pumpEventQueue();
      expect(ChildProcesses.phaseOf(101), isNull);

      final a = ChildProcesses.stop(102);
      await Future.wait([a, ChildProcesses.stop(102)]);
      expect(killed, [102]);

      await ChildProcesses.stopAll();
      expect(killed, [102, 103]);
      expect(ChildProcesses.tracked, isEmpty);
      expect(File('${dir.path}/quit.json').existsSync(), isTrue);
    });
  });

  group('Chrome host', () {
    test('a stop while Chrome starts ends the Chrome that lands late, and the host is closed', () async {
      final dir = await Directory.systemTemp.createTemp('chrome_host');
      addTearDown(() => dir.delete(recursive: true));
      // A stand-in Chrome: says where DevTools is after a moment, then waits.
      final fake = File('${dir.path}/chrome')
        ..writeAsStringSync(
          '#!/bin/sh\nsleep 0.3\necho "DevTools listening on ws://127.0.0.1:1/devtools/browser/x" >&2\n'
          'exec sleep 30\n',
        );
      await Process.run('chmod', ['+x', fake.path]);
      final stopped = <int>{};
      ProcessSupervisor.instance = ProcessSupervisor.create(
        ledgerDir: '${dir.path}/ledger',
        hooks: SupervisorHooks(
          signal: (p, s) {
            if (p > 0) stopped.add(p);
            return Process.killPid(p, s);
          },
        ),
      );
      final host = ChromeHost.of('${dir.path}/profile', executable: fake.path);
      final ready = host.endpoint(width: 800, height: 600);
      expect(host.state, isA<ChromeLaunching>());
      await host.stop();
      expect(host.state, isA<ChromeClosed>());
      await expectLater(ready, throwsA(isA<BrowserError>()));
      expect(stopped, isNotEmpty);
      expect(ChildProcesses.tracked, isEmpty);
    }, skip: Platform.isWindows);

    test('its flags keep crash reporting off', () {
      expect(ChromeHost.launchArgs('/p', 800, 600), containsAll(['--disable-breakpad', '--disable-crash-reporter']));
    });
  });

  test('the syntax cache stays small while a long file streams in', () {
    clearSyntaxCache();
    const line = 'final value = compute(items.map((e) => e.toString()).join(", "), 42); // note\n';
    final code = List.filled(800, line).join();
    const base = TextStyle(fontSize: 13);
    for (var n = 100; n < code.length; n += 100) {
      codeSpan(code.substring(0, n), 'dart', base: base, brightness: Brightness.dark);
    }
    // Before: up to 600 prefixes of the file, ~615 MB of spans in a probe.
    expect(syntaxCachedChars, lessThanOrEqualTo(syntaxCacheChars));
    for (var i = 0; i < 2000; i++) {
      codeSpan('x = $i;', 'dart', base: base, brightness: Brightness.dark);
    }
    expect(syntaxCachedChars, lessThanOrEqualTo(syntaxCacheChars));
  });

  test('a decoded frame is a usable image (its codec already let go)', () async {
    final png = Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 3)));
    final image = await decodeFirstFrame(png);
    expect((image.width, image.height), (4, 3));
    image.dispose();
  });

  test('pictures that will never be sent again leave the kept messages; what goes out is unchanged', () {
    Map<String, Object?> shot(int i) => {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'shot $i'},
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/png;base64,$i'},
        },
      ],
    };
    final kept = <Map<String, Object?>>[];
    final whole = <Map<String, Object?>>[];
    for (var i = 0; i < 30; i++) {
      kept.add(shot(i));
      whole.add(shot(i));
      dropOlderImages(kept, 4);
      expect(withOlderImagesNoted(kept, 4), withOlderImagesNoted(whole, 4), reason: 'after $i pictures');
    }
    final left = kept.expand((m) => m['content']! as List<Object?>).where((p) => (p! as Map)['type'] == 'image_url');
    expect(left.length, lessThan(8));
  });
}
