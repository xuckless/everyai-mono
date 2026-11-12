// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/environments/bridges.dart';
import 'package:every_ai/features/code/environments/discovery.dart';
import 'package:every_ai/features/code/environments/environment_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'env_fakes.dart';

void main() {
  ProviderContainer container(FakeRunner runner, Map<String, String> clis, {List<SshRemote> ssh = const []}) {
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(Preferences.inMemory({sshRemotesKey: encodeSshRemotes(ssh)})),
        environmentIoProvider.overrideWithValue(fakeIo(runner, clis: clis)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test("one failing kind doesn't hide the others", () async {
    final runner = FakeRunner({
      '/l list --json': ok(jsonEncode({'name': 'default', 'status': 'Running'})),
    });
    final c = container(
      runner,
      {'docker': '/d', 'limactl': '/l', 'multipass': '/m'},
      ssh: [const SshRemote.alias('x')],
    );
    final found = await c.read(environmentDiscoveryProvider.future);
    expect([for (final e in found.environments) e.id], ['host', 'lima:default']);
    expect(found.problems.keys.toSet(), {'docker', 'multipass', 'ssh'});
    expect(found.problems['ssh'], contains("ssh isn't installed"));
  });
}
