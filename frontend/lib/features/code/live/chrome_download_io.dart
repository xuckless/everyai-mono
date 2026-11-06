// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../git/git_service.dart';
import '../harness/everyai/browser_io.dart';
import 'chrome_pin.dart';

bool get chromeAvailable => HeadlessBrowser.find() != null;

/// This computer's platform name in Chrome for Testing's downloads.
String? get _platform {
  final arm = Abi.current() == Abi.macosArm64 || Abi.current() == Abi.linuxArm64;
  if (Platform.isMacOS) return arm ? 'mac-arm64' : 'mac-x64';
  if (Platform.isLinux) return arm ? 'linux-arm64' : 'linux64';
  if (Platform.isWindows) return 'win64';
  return null;
}

/// Where the unpacked browser's program is, inside [dir].
String _programIn(String dir, String platform) => switch (platform) {
  'mac-arm64' ||
  'mac-x64' => '$dir/chrome-$platform/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing',
  'win64' => '$dir\\chrome-win64\\chrome.exe',
  _ => '$dir/chrome-$platform/chrome',
};

Future<String> _home() async => '${await GitService.dataDir()}/chrome-for-testing/$chromeForTestingVersion';

Future<void> loadDownloadedChrome() async {
  final p = _platform;
  if (p == null || chromeForTestingVersion.isEmpty) return;
  try {
    final exe = _programIn(await _home(), p);
    if (File(exe).existsSync()) HeadlessBrowser.downloaded = exe;
  } on Object {
    // No app data folder (tests): nothing downloaded.
  }
}

Future<void> downloadChromeForTesting({void Function(double progress)? onProgress}) async {
  final p = _platform;
  final pin = p == null ? null : chromeForTestingPins[p];
  if (pin == null) throw StateError('there is no Chrome for Testing build pinned for this computer');
  final (url, sha) = pin;
  final home = await _home();
  final dir = Directory(home)..createSync(recursive: true);
  final zip = File('${dir.path}/chrome.zip');
  final client = HttpClient();
  try {
    final res = await (await client.getUrl(Uri.parse(url))).close();
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
    final total = res.contentLength;
    var got = 0;
    final sink = zip.openWrite();
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    await for (final chunk in res) {
      sink.add(chunk);
      hasher.add(chunk);
      got += chunk.length;
      if (total > 0) onProgress?.call(got / total * 0.95);
    }
    hasher.close();
    await sink.close();
    if ('${digest.value}' != sha) {
      zip.deleteSync();
      throw StateError('the download does not match its pinned SHA-256, so it was deleted');
    }
  } finally {
    client.close(force: true);
  }
  // The system's own unpacker keeps the app bundle's links and permissions.
  final r = Platform.isMacOS
      ? await Process.run('ditto', ['-x', '-k', zip.path, dir.path])
      : Platform.isWindows
      ? await Process.run('tar', ['-xf', zip.path, '-C', dir.path])
      : await Process.run('unzip', ['-q', '-o', zip.path, '-d', dir.path]);
  zip.deleteSync();
  if (r.exitCode != 0) throw StateError("couldn't unpack the browser: ${r.stderr}");
  onProgress?.call(1);
  await loadDownloadedChrome();
  if (HeadlessBrowser.downloaded == null) throw StateError('the browser was unpacked but its program is missing');
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
