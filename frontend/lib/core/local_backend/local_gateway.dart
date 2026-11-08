// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'local_backend.dart';

/// Where calls on the user's own provider keys go: the bundled server only
/// (owner, 2026-11-08). The hosted server refuses `X-Provider-Key-*` with a
/// 400 `keys_not_accepted`, so there is no fallback to it.
///
/// [resolve] is set by `modelBillingProvider` for code outside Riverpod (the
/// Code harness's gateway client and the summarizer); it starts the bundled
/// server when needed and answers null when there is none.
abstract final class LocalGateway {
  static Future<LocalBackendInfo?> Function()? resolve;

  /// What a call says when an own-key model has no bundled server to run on.
  static const missing =
      "Your own API keys run on the app's built-in EveryAI server, which isn't running. "
      'Restart EveryAI, or pick a model that runs without your key.';

  /// `…/v1/chat/completions` on the bundled server.
  static Uri completions(LocalBackendInfo info) => info.baseUrl.resolve('v1/chat/completions');

  /// The bundled server's headers for one own-key call: its launch token and
  /// the key; never the hosted gateway key.
  static Map<String, String> headers(LocalBackendInfo info, Map<String, String> keyHeaders) => {
    LocalBackendInfo.tokenHeader: info.token,
    ...keyHeaders,
  };
}
