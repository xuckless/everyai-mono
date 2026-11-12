import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/code_providers.dart' show harnessProvider;
import 'package:every_ai/features/code/drivers/acp/acp_driver.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/drivers/registry_install/acp_registry.dart';
import 'package:every_ai/features/code/drivers/registry_install/installed_agents.dart';
import 'package:every_ai/features/code/drivers/registry_install/registry_install_io.dart' show installBinary;
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _fixture = File('test/fixtures/drivers/acp_registry/registry.json').readAsStringSync();

RegistryAgent _agent(String id) => parseRegistry(_fixture).firstWhere((a) => a.id == id);

/// The listed ACP entries the registry agents may share a profile with.
Map<String, HarnessDriver> get _fixed => {
  for (final (id, command) in [
    ('gemini', 'gemini'),
    ('cline', 'cline'),
    ('grok', 'grok'),
    ('kiro', 'kiro-cli'),
    ('cursor', 'cursor-agent'),
    ('antigravity', 'agy'),
  ])
    id: AcpDriver(id: id, label: id, command: command),
};

String _registry(List<Map<String, Object?>> agents) => jsonEncode({'version': '1.0.0', 'agents': agents});

Map<String, Object?> _entry(String id, Map<String, Object?> distribution) => {
  'id': id,
  'name': id,
  'version': '1.0.0',
  'description': 'd',
  'distribution': distribution,
};

Uint8List _tarGz(List<ArchiveFile> files) {
  final a = Archive();
  files.forEach(a.addFile);
  return GZipEncoder().encodeBytes(TarEncoder().encodeBytes(a));
}

/// A zip made "on Unix" (each central entry's creator byte is 3), so its
/// modes and links are read as Unix ones.
Uint8List _zip(List<ArchiveFile> files) {
  final a = Archive();
  files.forEach(a.addFile);
  final bytes = ZipEncoder().encodeBytes(a);
  for (var i = 0; i + 6 <= bytes.length; i++) {
    if (bytes[i] == 0x50 && bytes[i + 1] == 0x4b && bytes[i + 2] == 0x01 && bytes[i + 3] == 0x02) bytes[i + 5] = 3;
  }
  return bytes;
}

/// A tar with a hard link [name] to [target] (the encoder writes none).
Uint8List _tarHardLink(String name, String target) {
  final out = OutputMemoryStream();
  (TarFile()
        ..filename = name
        ..typeFlag = TarFile.hardLink
        ..nameOfLinkedFile = target
        ..mode = 0x1a4)
      .write(out);
  out.writeBytes(Uint8List(1024));
  return GZipEncoder().encodeBytes(out.getBytes());
}

/// A zip symlink: its target as content, with the link file type.
ArchiveFile _zipLink(String name, String target) => ArchiveFile.string(name, target)..mode = 0xA1FF;

ArchiveFile _exe(String name) => ArchiveFile.string(name, '#!/bin/sh\necho hi\n')..mode = 0x1ed;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('registry_install'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('parseRegistry', () {
    test('leaves out an entry that breaks a rule and keeps the rest', () {
      final ok = _entry('ok', {
        'npx': {'package': 'ok@1.0.0'},
      });
      final agents = parseRegistry(
        _registry([
          ok,
          _entry('http', {
            'binary': {
              'linux-x86_64': {'archive': 'http://example.com/a.tar.gz', 'cmd': './a'},
            },
          }),
          _entry('unpinned', {
            'npx': {'package': 'some-agent'},
          }),
          _entry('latest', {
            'npx': {'package': 'some-agent@latest'},
          }),
          _entry('climb', {
            'binary': {
              'linux-x86_64': {'archive': 'https://example.com/a.tar.gz', 'cmd': '../x'},
            },
          }),
          _entry('abs', {
            'binary': {
              'linux-x86_64': {'archive': 'https://example.com/a.tar.gz', 'cmd': '/bin/sh'},
            },
          }),
          _entry('../bad', {
            'npx': {'package': 'ok@1.0.0'},
          }),
          {...ok, 'id': 'badver', 'version': '..'},
        ]),
      );
      expect([for (final a in agents) a.id], ['ok']);
    });
  });

  group('the registry client', () {
    final at = DateTime.utc(2026, 11, 4, 12);

    test('offline, the kept copy shows with a note', () async {
      final prefs = Preferences.inMemory({
        acpRegistryCacheKey: jsonEncode({'v': 1, 'fetchedAt': at.toIso8601String(), 'json': _fixture}),
      });
      final c = AcpRegistryClient(
        prefs,
        client: MockClient((_) async => throw http.ClientException('offline')),
        now: () => at.add(const Duration(hours: 3)),
      );
      final list = await c.load();
      expect(list.agents, hasLength(9));
      expect(list.note, contains('3 h ago'));
    });
  });

  group('platform pick', () {
    test('Windows on ARM falls back to x86_64; nothing for this computer is null', () {
      expect(pickDistribution(_agent('kilo'), 'windows-aarch64')!.binary!.cmd, 'kilo.exe');
      expect(pickDistribution(_agent('kiro'), 'windows-x86_64'), isNull);
    });
  });

  group('binary install', () {
    final chmodded = <String>[];
    AgentInstaller installer(Uint8List body, {int maxUnpacked = 1 << 20}) => AgentInstaller(
      client: MockClient((_) async => http.Response.bytes(body, 200)),
      dataDir: () async => tmp.path,
      platform: () => 'linux-x86_64',
      makeExecutable: (p) async => chmodded.add(p),
      maxUnpacked: maxUnpacked,
    );
    RegistryAgent agent(Uint8List body, {String cmd = './bin/agent', String url = 'a.tar.gz', bool sha = true}) =>
        RegistryAgent(
          id: 'demo',
          name: 'Demo',
          version: '1.2.3',
          binary: {
            'linux-x86_64': BinaryTarget(
              archive: 'https://example.com/$url',
              cmd: normalizeCommandPath(cmd)!,
              sha256: sha ? '${sha256.convert(body)}' : null,
              args: const ['acp'],
            ),
          },
        );
    setUp(chmodded.clear);

    test('a matching checksum installs under agents/<id>/<version>/', () async {
      final body = _tarGz([_exe('bin/agent'), ArchiveFile.string('README', 'x')]);
      final rec = await installer(body).install(agent(body));
      expect(rec.exe, '${tmp.path}/agents/demo/1.2.3/bin/agent');
      expect(File(rec.exe!).existsSync(), isTrue);
      expect(chmodded.single, endsWith('/bin/agent'));
      expect((rec.kind, rec.sha256Checked), (DistKind.binary, true));
      expect(rec.args, ['acp']);
      expect(Directory('${tmp.path}/agents/demo').listSync().map((e) => e.path.split('/').last), ['1.2.3']);
    });

    test('a checksum mismatch is refused and leaves nothing', () async {
      final body = _tarGz([_exe('bin/agent')]);
      final wrong = agent(_tarGz([_exe('bin/other')]));
      await expectLater(
        installer(body).install(wrong),
        throwsA(isA<InstallError>().having((e) => e.message, 'message', contains("didn't match its checksum"))),
      );
      expect(Directory('${tmp.path}/agents/demo').listSync(), isEmpty);
      expect(chmodded, isEmpty);
    });

    test('without a checksum it installs only when allowed', () async {
      final body = _tarGz([_exe('bin/agent')]);
      final a = agent(body, sha: false);
      await expectLater(installer(body).install(a), throwsA(isA<InstallError>()));
      expect(Directory('${tmp.path}/agents').existsSync(), isFalse);
      final rec = await installer(body).install(a, allowUnchecked: true);
      expect((File(rec.exe!).existsSync(), rec.sha256Checked), (true, false));
    });

    for (final (what, body) in [
      ('a tar entry ../evil', () => _tarGz([_exe('bin/agent'), ArchiveFile.string('../evil', 'x')])),
      ('a tar entry /abs', () => _tarGz([_exe('bin/agent'), ArchiveFile.string('/abs', 'x')])),
      ('a tar symlink to /etc', () => _tarGz([_exe('bin/agent'), ArchiveFile.symlink('l', '/etc')])),
      ('a tar symlink ../../x', () => _tarGz([_exe('bin/agent'), ArchiveFile.symlink('bin/l', '../../x')])),
      ('a tar hard link out', () => _tarHardLink('bin/agent', '../outside')),
      ('a zip entry ../evil', () => _zip([_exe('bin/agent'), ArchiveFile.string('../evil', 'x')])),
      ('a zip symlink out', () => _zip([_exe('bin/agent'), _zipLink('l', '../../etc/passwd')])),
    ]) {
      test('$what is refused and leaves nothing', () async {
        final bytes = body();
        final url = what.contains('zip') ? 'a.zip' : 'a.tar.gz';
        await expectLater(
          installer(bytes).install(agent(bytes, url: url)),
          throwsA(isA<InstallError>().having((e) => e.message, 'message', contains('outside its folder'))),
        );
        expect(Directory('${tmp.path}/agents/demo').listSync(), isEmpty);
        expect(File('${tmp.path}/evil').existsSync(), isFalse);
        expect(chmodded, isEmpty);
      });
    }

    test('unpacking past the size cap is refused', () async {
      final bytes = _tarGz([_exe('bin/agent'), ArchiveFile.bytes('big', Uint8List(4096))]);
      await expectLater(installer(bytes, maxUnpacked: 1024).install(agent(bytes)), throwsA(isA<InstallError>()));
      expect(Directory('${tmp.path}/agents/demo').listSync(), isEmpty);
    });

    test('a second install of the same agent is refused while the first runs', () async {
      final body = _tarGz([_exe('bin/agent')]);
      final gate = Completer<void>();
      final c = ProviderContainer(
        overrides: [
          harnessProvider.overrideWithValue(FakeHarness()),
          preferencesProvider.overrideWithValue(Preferences.inMemory()),
          driverRegistryProvider.overrideWithValue(DriverRegistry(const {})),
          rescanHarnessesProvider.overrideWithValue((_) {}),
          agentInstallerProvider.overrideWithValue(
            AgentInstaller(
              client: MockClient((_) async {
                await gate.future;
                return http.Response.bytes(body, 200);
              }),
              dataDir: () async => tmp.path,
              platform: () => 'linux-x86_64',
              makeExecutable: (_) async {},
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final notifier = c.read(installedAgentsProvider.notifier);
      final first = notifier.install(agent(body));
      expect(c.read(agentsInFlightProvider), {'demo'});
      await expectLater(notifier.install(agent(body)), throwsA(isA<InstallError>()));
      await expectLater(notifier.remove('demo'), throwsA(isA<InstallError>()));
      gate.complete();
      await first;
      expect(c.read(agentsInFlightProvider), isEmpty);
      expect(File(c.read(installedAgentsProvider)['demo']!.exe!).existsSync(), isTrue);
    });

    for (final (what, response) in [
      ('no answer', () => Completer<http.StreamedResponse>().future),
      ('a stream that stops', () async => http.StreamedResponse(StreamController<List<int>>().stream, 200)),
    ]) {
      test('a download with $what gives up and leaves nothing', () async {
        await expectLater(
          installBinary(
            root: '${tmp.path}/agents',
            id: 'demo',
            version: '1',
            target: const BinaryTarget(archive: 'https://example.com/a.tar.gz', cmd: 'bin/agent'),
            client: _Stalled(response),
            makeExecutable: (_) async {},
            maxDownload: 1 << 20,
            maxUnpacked: 1 << 20,
            idle: Duration.zero,
          ),
          throwsA(isA<InstallError>().having((e) => e.message, 'message', contains('stopped'))),
        );
        expect(Directory('${tmp.path}/agents/demo').listSync(), isEmpty);
      });
    }
  });

  group('command lines', () {
    InstalledAgent rec(String id, {String platform = 'darwin-aarch64', String? exe}) {
      final a = _agent(id);
      final d = pickDistribution(a, platform)!;
      return InstalledAgent(
        id: a.id,
        name: a.name,
        version: a.version,
        kind: d.kind,
        exe: exe,
        package: d.run?.package,
        home: d.kind == DistKind.binary ? null : '/data/agents/$id',
        args: d.args,
        env: d.env,
      );
    }

    List<String> line(AcpDriver d) => [d.resolved.executable, ...d.resolved.args];

    test('gemini through npx keeps its ACP flag', () {
      expect(line(registryDriver(rec('gemini'), _fixed)), [
        'npx',
        '--prefix',
        '/data/agents/gemini',
        '-y',
        '@google/gemini-cli@0.66.0',
        '--acp',
      ]);
    });
  });

  group('the driver layer', () {
    const gemini = InstalledAgent(
      id: 'gemini',
      name: 'Gemini CLI',
      version: '0.66.0',
      kind: DistKind.npx,
      package: '@google/gemini-cli@0.66.0',
      home: '/data/agents/gemini',
    );

    test('records survive a round trip through Preferences', () {
      final prefs = Preferences.inMemory({
        installedAgentsKey: jsonEncode({
          'v': 1,
          'agents': {'gemini': gemini.toJson(), 'broken': 'x'},
        }),
      });
      final read = readInstalledAgents(prefs);
      expect(read.keys, ['gemini']);
      expect(read['gemini']!.home, '/data/agents/gemini');
      expect(jsonEncode(read['gemini']!.toJson()), jsonEncode(gemini.toJson()));
    });
  });

  group('consent', () {
    DriverInfo info(String id, DistKind kind, {String? exe, String? package}) => registryDriver(
      InstalledAgent(id: id, name: id, version: '1', kind: kind, exe: exe, package: package),
      _fixed,
    ).info;

    test('follows the listed entry, the program, or asks for an unknown one', () {
      final gemini = info('gemini', DistKind.npx, package: 'g@1.0.0');
      expect((gemini.needsConsent, gemini.consentId), (true, 'gemini'));
      final cline = info('cline', DistKind.npx, package: 'cline@1.0.0');
      expect((cline.needsConsent, cline.consentId), (false, 'cline'));
      final claude = info('claude-acp', DistKind.npx, package: 'c@1.0.0');
      expect((claude.needsConsent, claude.consentId), (true, 'registry:claude-acp'));
      expect(info('opencode', DistKind.binary, exe: '/x/opencode').needsConsent, isFalse);
      final agy = info('antigravity-acp', DistKind.binary, exe: '/x/agy_acp_server.par');
      expect((agy.needsConsent, agy.consentId), (true, 'registry:antigravity-acp'));
    });
  });
}

/// A client whose answer is [response].
final class _Stalled extends http.BaseClient {
  _Stalled(this.response);
  final Future<http.StreamedResponse> Function() response;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => response();
}
