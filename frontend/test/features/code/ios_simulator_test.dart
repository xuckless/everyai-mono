// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:typed_data';

import 'package:every_ai/features/code/live/app_endpoints.dart';
import 'package:every_ai/features/code/live/ios_simulator_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('simctl devices: iOS and iPadOS only, runtime names, booted', () {
    final json = jsonEncode({
      'devices': {
        'com.apple.CoreSimulator.SimRuntime.iOS-18-6': [
          {'udid': 'A', 'name': 'iPhone 16', 'state': 'Booted', 'isAvailable': true},
          {'udid': 'B', 'name': 'iPhone 16 Pro', 'state': 'Shutdown', 'isAvailable': true},
          {'udid': 'C', 'name': 'Broken', 'state': 'Shutdown', 'isAvailable': false},
        ],
        'com.apple.CoreSimulator.SimRuntime.watchOS-11-0': [
          {'udid': 'W', 'name': 'Watch', 'state': 'Booted'},
        ],
      },
    });
    final d = parseSimctlDevices(json);
    expect(d.map((x) => x.name), ['iPhone 16', 'iPhone 16 Pro']);
    expect(d.first.runtime, 'iOS 18.6');
    expect(d.first.booted, isTrue);
    expect(parseSimctlDevices('not json'), isEmpty);
  });

  test('accessibility tree: roles, states, secrets, keyboard folded, reading order', () {
    Map<String, Object?> n(
      String type, {
      String? label,
      String? value,
      double y = 100,
      double x = 10,
      bool on = true,
    }) => {
      'type': type,
      'AXLabel': label,
      'AXValue': value,
      'enabled': on,
      'frame': {'x': x, 'y': y, 'width': 80, 'height': 30},
      'children': <Object?>[],
    };
    final keys = [for (final k in 'qwertyuiopasdfghjkl'.split('')) n('Button', label: k, y: 900)];
    final tree = [
      {
        'type': 'Application',
        'frame': {'x': 0, 'y': 0, 'width': 393, 'height': 852},
        'children': [
          n('Button', label: 'Save', y: 300),
          n('StaticText', label: 'Title', y: 50),
          n('TextField', label: 'Name', value: 'Ada', y: 200),
          n('SecureTextField', label: 'Password', value: '••••', y: 250),
          n('Switch', label: 'Pin', value: '1', y: 350),
          n('Button', label: 'Off', on: false, y: 400),
          n('Button', label: 'Save', y: 300, x: 10), // listed twice
          ...keys,
        ],
      },
    ];
    final r = flattenAxTree(tree);
    expect(r.width, 393);
    expect(r.height, 852);
    final lines = [for (final x in r.nodes) '${x.role} ${x.name} ${x.value} ${x.state}'];
    expect(lines.first, startsWith('text Title'));
    expect(lines.where((l) => l.startsWith('button Save')), hasLength(1));
    expect(lines, contains('textbox Name Ada []'));
    final pw = r.nodes.firstWhere((x) => x.name == 'Password');
    expect(pw.secret, isTrue);
    expect(pw.value, isNull);
    expect(lines, contains('switch Pin null [checked]'));
    expect(lines, contains('button Off null [disabled]'));
    expect(lines.any((l) => l.startsWith('button q')), isFalse);
    // The keyboard sits off screen here, so no note.
    expect(lines.any((l) => l.contains('keyboard')), isFalse);
  });

  test('MJPEG frames are cut by Content-Length, across chunks, with early end markers inside', () async {
    Uint8List part(List<int> jpeg) => Uint8List.fromList([
      ...latin1.encode('--mjpegstream\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.length}\r\n\r\n'),
      ...jpeg,
      ...latin1.encode('\r\n'),
    ]);
    final a = [0xFF, 0xD8, 1, 2, 0xFF, 0xD9, 3, 4, 0xFF, 0xD9]; // a thumbnail's end marker first
    final b = [0xFF, 0xD8, 9, 0xFF, 0xD9];
    final all = [...part(a), ...part(b)];
    final chunks = [all.sublist(0, 7), all.sublist(7, 40), all.sublist(40)];
    final frames = await Stream.fromIterable(chunks).transform(MjpegFrames()).toList();
    expect(frames, [a, b]);
  });

  test('simulators named in output', () {
    const udid = 'AE1D9E23-5039-45F6-B6A6-8059F2208FD6';
    final found = detectAppEndpoints(
      r'Launching lib/main.dart on iPhone 16 in debug mode...'
      '\nxcrun simctl boot $udid\n',
    );
    expect(found.where((e) => e.kind == AppKind.ios).map((e) => '${e.uri}'), {
      'simulator:$udid',
      'simulator-name:iPhone%2016',
    });
    expect(simulatorMentions('npx expo run:ios -d "iPad Air 11-inch (M3)"').single.path, 'iPad%20Air%2011-inch%20(M3)');
  });

  test('a simulator is held by one session at a time', () {
    expect(IosSimulators.claim('X', 'a'), isNull);
    expect(IosSimulators.claim('X', 'a'), isNull);
    expect(IosSimulators.claim('X', 'b'), 'a');
    expect(IosSimulators.heldBy('a'), ['X']);
    IosSimulators.release('a');
    expect(IosSimulators.claim('X', 'b'), isNull);
    IosSimulators.release('b');
  });
}
