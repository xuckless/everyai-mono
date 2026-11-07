import 'package:every_ai/features/remote/data/host_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('replaced and revoked are final: a later hello or drop changes nothing', () {
    const s = HostLinkState();
    expect(s.status, HostLinkStatus.connecting);
    final online = s.to(HostLinkStatus.online);
    expect(online.connected, isTrue);
    expect(online.to(HostLinkStatus.connecting).connected, isFalse);
    final replaced = online.to(HostLinkStatus.replaced);
    expect(replaced.to(HostLinkStatus.online).status, HostLinkStatus.replaced);
    expect(replaced.to(HostLinkStatus.connecting).replaced, isTrue);
    expect(s.to(HostLinkStatus.revoked).to(HostLinkStatus.replaced).revoked, isTrue);
  });
}
