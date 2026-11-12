// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/features/code/drivers/json_rpc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/replay_transport.dart';

void main() {
  test('error replies throw, and pending requests fail when the agent goes away', () async {
    final channel = ReplayChannel('''
{"dir":"out","msg":{"jsonrpc":"2.0","id":1,"method":"a"}}
{"dir":"in","msg":{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"nope"}}}
{"dir":"out","msg":{"jsonrpc":"2.0","id":2,"method":"b"}}
{"dir":"eof"}
''');
    final peer = JsonRpcPeer(channel);
    await expectLater(peer.request('a'), throwsA(isA<JsonRpcError>().having((e) => e.message, 'message', 'nope')));
    await expectLater(
      peer.request('b'),
      throwsA(isA<JsonRpcError>().having((e) => e.code, 'code', JsonRpcError.closedCode)),
    );
    await peer.done;
    await expectLater(peer.request('c'), throwsA(isA<JsonRpcError>()));
  });
}
