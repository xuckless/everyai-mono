import 'dart:io';

import 'package:cronet_http/cronet_http.dart';
import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

http.Client createClient({required String userAgent}) {
  if (Platform.isIOS || Platform.isMacOS) {
    final config = URLSessionConfiguration.ephemeralSessionConfiguration()
      ..httpAdditionalHeaders = {'User-Agent': userAgent}
      ..waitsForConnectivity = false;
    return CupertinoClient.fromSessionConfiguration(config);
  }
  if (Platform.isAndroid) {
    final engine = CronetEngine.build(
      cacheMode: CacheMode.memory,
      cacheMaxSize: 2 * 1024 * 1024,
      enableBrotli: true,
      enableHttp2: true,
      enableQuic: true,
      userAgent: userAgent,
    );
    return CronetClient.fromCronetEngine(engine, closeEngine: true);
  }
  return IOClient(HttpClient()..userAgent = userAgent);
}
