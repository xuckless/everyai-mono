import 'package:web_socket/web_socket.dart';

Future<WebSocket> connectRelay(Uri url, String token, {String? userToken}) =>
    WebSocket.connect(url.replace(queryParameters: {...url.queryParameters, 'token': token, 'user_token': ?userToken}));
