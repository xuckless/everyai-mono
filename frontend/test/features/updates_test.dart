// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/updates/data/install.dart';
import 'package:every_ai/features/updates/data/sparkle_bridge.dart';
import 'package:every_ai/features/updates/domain/releases.dart';
import 'package:every_ai/features/updates/update_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ReleaseVersion v(String s) => ReleaseVersion.tryParse(s)!;

Map<String, Object?> _release(String tag, {bool pre = false, bool draft = false, List<String> files = const []}) => {
  'tag_name': tag,
  'prerelease': pre,
  'draft': draft,
  'html_url': 'https://github.com/x/y/releases/tag/$tag',
  'body': 'notes',
  'assets': [
    for (final f in files) {'name': f, 'browser_download_url': 'https://dl/$tag/$f', 'size': 10},
  ],
};

/// Signed by a throwaway key with `packaging/updates.py` (keygen, then sign a file holding [_sums]).
const _testKey = 'Ws6PXXn6eoX0y5rg1ChtoUM3rpXqWZflow4HdUARNNY=';
const _sums = 'abc  EveryAI-0.2.0-x86_64.AppImage\n';
const _sumsSig = 'ILwwb/SFZJ98uUa4Xo1Yi/F5X9CXJSs6W1rO064PxnfkwMzWg4gap/wmwVjo5ZJmp9Y8O8zcUIiWw2d+PFKcAw==';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('versions', () {
    test('checksums and their signature', () async {
      expect(checksumFor('${'a' * 64}  x.deb\n${'B' * 64} *EveryAI.AppImage', 'EveryAI.AppImage'), 'b' * 64);
      expect(checksumFor('${'a' * 64}  x.deb', 'y'), isNull);
      // A signature made by packaging/updates.py verifies here: the CI signer and the app agree.
      expect(await verifySigned(_sums, _sumsSig, publicKey: _testKey), isTrue);
      expect(await verifySigned('${_sums}tampered', _sumsSig, publicKey: _testKey), isFalse);
      expect(await verifySigned(_sums, 'not base64!', publicKey: _testKey), isFalse);
    });
  });

  group('controller', () {
    late List<String> requested;

    ProviderContainer container({
      required InstallKind kind,
      required Object releases,
      Map<String, String> prefs = const {},
      SparkleBridge? sparkle,
      Future<void> Function(Release, {required http.Client client, void Function(double)? onProgress})? stage,
      Duration sparkleTimeout = const Duration(minutes: 15),
    }) {
      requested = [];
      final c = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(Preferences.inMemory({...prefs})),
          updateEnvProvider.overrideWithValue(
            UpdateEnv(
              detect: (_) async => kind,
              current: v('0.1.0-alpha.1'),
              sparkle: sparkle,
              client: () => MockClient((req) async {
                requested.add(req.url.toString());
                return http.Response(jsonEncode(releases), 200);
              }),
              stage: stage ?? (r, {required client, onProgress}) async => onProgress?.call(1),
              restartImage: () async {},
              sparkleTimeout: sparkleTimeout,
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('an AppImage downloads the update and waits for a restart', () async {
      final c = container(
        kind: InstallKind.appImage,
        releases: _release(
          'v0.1.0-alpha.2',
          files: ['EveryAI-0.1.0-alpha.2-x86_64.AppImage', 'SHA256SUMS', 'SHA256SUMS.sig'],
        ),
      );
      await c.read(updateProvider.notifier).check();
      final s = c.read(updateProvider);
      expect(s.phase, UpdatePhase.ready);
      expect(s.showBanner, isTrue);
      expect(requested.single, endsWith('/releases/latest'), reason: 'stable channel asks for the latest only');
      c.read(updateProvider.notifier).later();
      expect(c.read(updateProvider).showBanner, isFalse);
    });

    test('a failed verification shows as failed and touches nothing', () async {
      final c = container(
        kind: InstallKind.appImage,
        releases: _release('v0.1.0-alpha.2', files: ['a.AppImage', 'SHA256SUMS', 'SHA256SUMS.sig']),
        stage: (r, {required client, onProgress}) async =>
            throw const UpdateError("The release's checksums aren't signed by EveryAI."),
      );
      await c.read(updateProvider.notifier).check();
      expect(c.read(updateProvider).phase, UpdatePhase.failed);
      expect(c.read(updateProvider).error, contains('signed'));
      expect(c.read(updateProvider).showBanner, isFalse);
    });

    test('dev and store installs never ask GitHub', () async {
      final c = container(kind: InstallKind.none, releases: _release('v9.0.0'));
      await c.read(updateProvider.notifier).check();
      expect(requested, isEmpty);
      expect(c.read(updateProvider).supported, isFalse);
    });
  });
}
