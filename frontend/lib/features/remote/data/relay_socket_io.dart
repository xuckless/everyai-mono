import 'dart:io' as io;

import 'package:web_socket/io_web_socket.dart';
import 'package:web_socket/web_socket.dart';

Future<WebSocket> connectRelay(Uri url, String token, {String? userToken}) async {
  // Closed through the returned WebSocket.
  // ignore: close_sinks
  final socket = await io.WebSocket.connect(
    url.toString(),
    headers: {'Authorization': 'Bearer $token', 'X-User-Token': ?userToken},
  );
  return IOWebSocket.fromWebSocket(socket);
}
