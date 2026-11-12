import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/package_check.dart';
import 'package:every_ai/features/code/harness/everyai/package_registry_io.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Registry answers by URL path (small fixtures written by hand, shaped like each registry's JSON).
const _fixtures = <String, Object>{
  '/downloads/point/last-week/left-pad': {'downloads': 2500000, 'package': 'left-pad'},
  '/downloads/point/last-week/tiny-thing': {'downloads': 12, 'package': 'tiny-thing'},
  '/tiny-thing': {
    'dist-tags': {'latest': '1.0.0'},
    'time': {'created': '2026-11-01T10:00:00.000Z'},
    'versions': {
      '1.0.0': {
        'scripts': {'postinstall': 'node x.js'},
      },
    },
  },
  '/pypi/reqests/json': {
    'releases': {
      '0.1': [
        {'upload_time_iso_8601': '2026-10-20T00:00:00Z'},
      ],
      '0.0.1': [
        {'upload_time_iso_8601': '2026-10-19T00:00:00Z'},
      ],
    },
  },
  '/api/v1/crates/serde-thing': {
    'crate': {'created_at': '2019-01-01T00:00:00Z', 'recent_downloads': 300},
  },
  '/api/v1/gems/railz.json': {'downloads': 77},
  '/api/packages/fancy_pkg': {
    'versions': [
      {'published': '2025-01-02T00:00:00Z'},
      {'published': '2024-05-06T00:00:00Z'},
    ],
  },
  '/github.com/acme/tool/@latest': {'Version': 'v1.0.0'},
};

void main() {
  group('RegistryLookup', () {
    late List<Uri> asked;
    late Object? Function(http.Request) override;
    late RegistryLookup lookup;
    late DateTime now;

    setUp(() {
      asked = [];
      override = (_) => null;
      now = DateTime.utc(2026, 11, 5);
      lookup = RegistryLookup(
        clock: () => now,
        MockClient((req) async {
          asked.add(req.url);
          if (override(req) case final Object o) {
            if (o is http.Response) return o;
            throw o;
          }
          final body = _fixtures[req.url.path];
          return body == null ? http.Response('{"error":"not found"}', 404) : http.Response(jsonEncode(body), 200);
        }),
      );
    });

    test('npm: a little-used package gets its packument (age, install script)', () async {
      final info = await lookup.info(const PackageRef(Ecosystem.npm, 'tiny-thing'));
      expect(info!.downloads, 12);
      expect(info.created, DateTime.utc(2026, 11, 1, 10));
      expect(info.installScript, isTrue);
      expect(asked.map((u) => u.host), ['api.npmjs.org', 'registry.npmjs.org']);
    });

    test('failures are unknown and not cached; answers are cached', () async {
      for (final failure in [http.ClientException('offline'), TimeoutException('slow'), http.Response('busy', 503)]) {
        override = (_) => failure;
        expect(await lookup.info(const PackageRef(Ecosystem.pypi, 'reqests')), isNull);
        now = now.add(lookup.downFor);
      }
      override = (_) => null;
      expect(await lookup.info(const PackageRef(Ecosystem.pypi, 'reqests')), isNotNull);
      final before = asked.length;
      expect(await lookup.info(const PackageRef(Ecosystem.pypi, 'reqests')), isNotNull);
      expect(asked.length, before);
    });

    test('a registry that failed is skipped for a while, the others are not', () async {
      override = (_) => http.ClientException('dropped');
      expect(await lookup.info(const PackageRef(Ecosystem.pypi, 'reqests')), isNull);
      override = (_) => null;
      final before = asked.length;
      expect(await lookup.info(const PackageRef(Ecosystem.pypi, 'other')), isNull);
      expect(asked.length, before);
      expect(await lookup.info(const PackageRef(Ecosystem.npm, 'left-pad')), isNotNull);
      now = now.add(lookup.downFor);
      expect((await lookup.info(const PackageRef(Ecosystem.pypi, 'reqests')))!.exists, isTrue);
    });
  });

  group('PackageGuard', () {});

  group('ToolRunner bash with the package check', () {
    late Directory tmp;
    late SessionShell shell;
    late ToolRunner runner;
    late _FakeLookup fake;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('everyai-pkg');
      Directory('${tmp.path}/bin').createSync();
      // A stand-in npm: records that it ran and, when asked, writes a lockfile.
      File('${tmp.path}/bin/npm')
          .writeAsStringSync('#!/bin/sh\ntouch ran\n[ -f lock.next ] && cp lock.next package-lock.json\nexit 0\n');
      Process.runSync('chmod', ['+x', '${tmp.path}/bin/npm']);
      fake = _FakeLookup({
        'npm:lodahs': PackageInfo.missing,
        'npm:fresh-thing': PackageInfo(created: DateTime.now().subtract(const Duration(days: 2)), downloads: 3),
        'npm:old-thing': PackageInfo(created: DateTime.utc(2018), downloads: 50000),
      });
      shell = SessionShell(root: tmp.path, sessionTag: 't', scratchDir: '${tmp.path}/.sh');
      runner = ToolRunner(
        root: tmp.path,
        shell: shell,
        gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: 'sk-eai-test-key-000000'),
        sessionTag: 't',
        packages: PackageGuard(fake, env: const {}),
      );
    });
    tearDown(() async {
      await shell.killAll();
      tmp.deleteSync(recursive: true);
    });

    String npm(String args) => 'PATH=${tmp.path}/bin:/usr/bin:/bin npm $args';

    test('a made-up name is refused and never reaches the shell, in Bypass too', () async {
      for (final bypass in [false, true]) {
        runner.bypass = bypass;
        final out = await runner.run('bash', {'command': 'touch marker && ${npm('i lodahs')}'});
        expect(out.isError, isTrue);
        expect(out.text, contains("`lodahs` doesn't exist on npm. Did you mean `lodash`?"));
        expect(File('${tmp.path}/marker').existsSync(), isFalse);
        expect(File('${tmp.path}/ran').existsSync(), isFalse);
      }
    });

    test('an install the check refuses is refused before it is shown for approval', () async {
      expect(await runner.packageRefusal('bash', {'command': npm('i lodahs')}), contains("`lodahs` doesn't exist"));
      expect(await runner.packageRefusal('bash', {'command': npm('i old-thing')}), isNull);
      expect(await runner.packageRefusal('read', {'path': 'x'}), isNull);
      expect(File('${tmp.path}/ran').existsSync(), isFalse);
    });
  });
}

final class _FakeLookup implements PackageLookup {
  _FakeLookup(this.answers);

  final Map<String, PackageInfo?> answers;
  final asked = <String>[];

  @override
  Future<PackageInfo?> info(PackageRef p) async {
    asked.add(p.key);
    return answers[p.key];
  }
}
