import 'package:http/http.dart' as http;

import 'http_client_io.dart' if (dart.library.js_interop) 'http_client_web.dart' as impl;

/// Returns the best HTTP client for the host:
/// - iOS/macOS: NSURLSession (HTTP/2, HTTP/3, system proxy/VPN, cellular rules)
/// - Android: Cronet (HTTP/2, HTTP/3 + QUIC, Brotli)
/// - Web: fetch with streamed responses (needed for SSE)
/// - Windows/Linux: dart:io (HTTP/1.1; the Dart IO stack has no HTTP/2 client)
http.Client createPlatformHttpClient({required String userAgent}) => impl.createClient(userAgent: userAgent);
