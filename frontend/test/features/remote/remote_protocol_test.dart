import 'dart:typed_data';

import 'package:every_ai/features/remote/domain/remote_protocol.dart';
import 'package:every_ai/features/remote/remote_providers.dart' show hostOffers;
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

  group('host paths', () {
    test('normalize . and .. and refuse what climbs out or is relative', () {
      expect(normalizeHostPath('/work/app/./lib/..'), '/work/app');
      expect(normalizeHostPath('/work//app/'), '/work/app');
      expect(normalizeHostPath('/work/../..'), isNull);
      expect(normalizeHostPath('work/app'), isNull);
      expect(normalizeHostPath(r'C:\Users\me\..\app'), 'C:/Users/app');
    });

    test('a folder is offered only inside a project', () {
      const roots = ['/work/app', '/wt/s1/'];
      expect(hostOffers('/work/app', roots), isTrue);
      expect(hostOffers('/work/app/lib', roots), isTrue);
      expect(hostOffers('/wt/s1', roots), isTrue);
      expect(hostOffers('/work/app/../../etc', roots), isFalse);
      expect(hostOffers('/work/apple', roots), isFalse);
      expect(hostOffers('lib', roots), isFalse);
    });

    test('routes name the conversation they reach', () {
      expect(conversationInPath('api/conversations/abc-1/events?x=1'), 'abc-1');
      expect(conversationInPath('sockets/events/abc-1?resend_mode=all'), 'abc-1');
      expect(conversationInPath('api/conversations?ids=a'), isNull);
      expect(conversationInPath('everyai/projects'), isNull);
    });
  });
}
