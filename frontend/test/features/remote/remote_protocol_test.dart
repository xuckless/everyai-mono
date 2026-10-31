import 'dart:typed_data';

import 'package:every_ai/features/remote/domain/remote_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tunnel parts', () {
    test('a short message is one plain frame', () {
      final parts = Tunnel.split({'t': 'res', 'id': 1, 'body': 'ok'});
      expect(parts, hasLength(1));
      expect(TunnelAssembler().add(parts.single), {'t': 'res', 'id': 1, 'body': 'ok'});
    });

    test('a long one goes in parts under the cap and comes back whole', () {
      final message = {'t': 'ws', 'id': 3, 'data': 'é' * 5000};
      final parts = Tunnel.split(message, maxPart: 1000);
      expect(parts.length, greaterThan(9));
      expect(parts.every((p) => p.length <= 1000), isTrue);
      final assembler = TunnelAssembler();
      final out = [for (final p in parts) assembler.add(p)];
      expect(out.take(out.length - 1), everyElement(isNull));
      expect(out.last, message);
    });

    test('a message past the limit is dropped, and the next one still reads', () {
      final assembler = TunnelAssembler(maxMessage: 2000);
      for (final p in Tunnel.split({'t': 'ws', 'id': 1, 'data': 'x' * 5000}, maxPart: 500)) {
        expect(assembler.add(p), isNull);
      }
      expect(assembler.add(Tunnel.split({'t': 'res', 'id': 2})[0]), {'t': 'res', 'id': 2});
      expect(assembler.add(Uint8List(0)), isNull);
    });
  });
}
