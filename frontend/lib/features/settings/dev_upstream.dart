import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_client.dart';
import '../../core/providers.dart';

/// Which key pays for Claude models (dev builds): the backend's
/// `GET/PUT /v1/dev/upstream`. Server-wide; Search and Research always use
/// OpenRouter.
enum ClaudeUpstream {
  openrouter('OpenRouter'),
  anthropic('Anthropic key');

  const ClaudeUpstream(this.label);
  final String label;
}

@immutable
final class DevUpstream {
  const DevUpstream({required this.claude, required this.hasAnthropicKey});

  factory DevUpstream.fromJson(Map<String, Object?> j) => DevUpstream(
    claude: j['anthropic'] == 'anthropic' ? ClaudeUpstream.anthropic : ClaudeUpstream.openrouter,
    hasAnthropicKey: switch (j['keys']) {
      {'anthropic': final bool v} => v,
      _ => false,
    },
  );

  final ClaudeUpstream claude;
  final bool hasAnthropicKey;
}

final devUpstreamProvider = AsyncNotifierProvider.autoDispose<DevUpstreamController, DevUpstream>(
  DevUpstreamController.new,
);

final class DevUpstreamController extends AsyncNotifier<DevUpstream> {
  ApiClient get _api => ref.read(apiClientProvider);
  bool get _authenticated => !ref.read(appConfigProvider).devSkipAuth;

  @override
  Future<DevUpstream> build() async =>
      DevUpstream.fromJson(await _api.getJson('v1/dev/upstream', authenticated: _authenticated));

  Future<void> set(ClaudeUpstream to) async {
    state = await AsyncValue.guard(
      () async => DevUpstream.fromJson(
        await _api.putJson('v1/dev/upstream', {'anthropic': to.name}, authenticated: _authenticated),
      ),
    );
  }
}
