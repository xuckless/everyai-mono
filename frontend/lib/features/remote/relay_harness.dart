import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/adapter_web_socket_channel.dart';

import '../code/harness/events.dart';
import '../code/harness/harness.dart';
import '../code/harness/openhands_harness.dart';
import 'data/relay_client.dart';

/// Code sessions on a paired host, from a phone, a tablet or the web: the
/// agent-server protocol of [OpenHandsHarness], carried through the
/// encrypted tunnel of a [RemoteClient] instead of a local socket.
///
/// The host bridges each call to its own agent-server and adds the session
/// key, so the address here is a placeholder and the key is empty.
final class RelayHarness implements Harness {
  RelayHarness(this.client)
    : _inner = OpenHandsHarness.located(
        () async => (_placeholder, ''),
        client: RelayHttpClient(client),
        connectSocket: (url) => AdapterWebSocketChannel(client.openSocket(_relative(url))),
      );

  final RemoteClient client;
  final OpenHandsHarness _inner;

  static final _placeholder = Uri.parse('http://remote-host.invalid/');

  /// [url]'s path and query under the placeholder, as the host resolves it.
  static String _relative(Uri url) {
    final path = url.path.startsWith('/') ? url.path.substring(1) : url.path;
    return url.hasQuery ? '$path?${url.query}' : path;
  }

  @override
  Future<HarnessSession> start(SessionSpec spec) => _guard(() => _inner.start(spec));

  @override
  Future<HarnessSession> attach(String conversationId) => _guard(() => _inner.attach(conversationId));

  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) =>
      _guard(() => _inner.statuses(conversationIds));

  /// The host being away reads as a harness error, as a stopped sidecar does.
  static Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on RemoteUnavailable catch (e) {
      throw HarnessError(e.message);
    } on http.ClientException catch (e) {
      throw HarnessError(e.message);
    }
  }
}

/// An [http.Client] whose requests go through the tunnel to the host.
final class RelayHttpClient extends http.BaseClient {
  RelayHttpClient(this._client);

  final RemoteClient _client;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    final res = await () async {
      try {
        return await _client.request(
          request.method,
          RelayHarness._relative(request.url),
          body: bytes.isEmpty ? null : utf8.decode(bytes),
        );
      } on RemoteUnavailable catch (e) {
        throw http.ClientException(e.message, request.url);
      }
    }();
    final body = utf8.encode(res.body);
    return http.StreamedResponse(
      Stream.value(body),
      res.status,
      contentLength: body.length,
      request: request,
      headers: const {'content-type': 'application/json'},
    );
  }
}
