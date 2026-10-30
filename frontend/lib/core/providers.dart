import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/data/token_store.dart';
import 'config/app_config.dart';
import 'db/app_database.dart';
import 'net/api_client.dart';
import 'net/http_client.dart';

/// App-wide singletons. Override these in tests (e.g. an in-memory database).

final appConfigProvider = Provider<AppConfig>((ref) => AppConfig.fromEnvironment());

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// One pooled client for the whole app (HTTP/2 and QUIC sessions get reused).
final apiClientProvider = Provider<ApiClient>((ref) {
  final config = ref.watch(appConfigProvider);
  final client = ApiClient(
    baseUrl: config.apiBaseUrl,
    client: createPlatformHttpClient(userAgent: 'EveryAI/0.1'),
    tokens: ref.watch(tokenStoreProvider),
  );
  ref.onDispose(client.close);
  return client;
});
