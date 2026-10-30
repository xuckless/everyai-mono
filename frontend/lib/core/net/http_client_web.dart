import 'package:fetch_client/fetch_client.dart';
import 'package:http/http.dart' as http;

// Browsers set User-Agent themselves and reject overrides.
http.Client createClient({required String userAgent}) =>
    FetchClient(mode: RequestMode.cors, credentials: RequestCredentials.omit);
