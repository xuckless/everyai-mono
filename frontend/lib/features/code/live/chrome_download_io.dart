// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import '../../../core/process/supervisor.dart';
import '../git/git_service.dart';
import '../harness/everyai/browser_io.dart';
import 'chrome_pin.dart';
import 'verified_download_io.dart';

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

/// One download at a time (the Preview's button and the agent may both ask).
Future<void>? _downloading;

Future<void> downloadChromeForTesting({void Function(double progress)? onProgress}) =>
    _downloading ??= _download(onProgress).whenComplete(() => _downloading = null);

Future<void> _download(void Function(double progress)? onProgress) async {
  final p = _platform;
  final pin = p == null ? null : chromeForTestingPins[p];
  if (pin == null) throw StateError('there is no Chrome for Testing build pinned for this computer');
  final (url, sha) = pin;
  final home = await _home();
  final dir = Directory(home)..createSync(recursive: true);
  final zip = File('${dir.path}/chrome.zip.part');
  final unpacked = Directory('${dir.path}/chrome-$p');
  var ok = false;
  try {
    await downloadVerified(Uri.parse(url), sha, zip, onProgress: (p) => onProgress?.call(p * 0.95));
    // The system's own unpacker keeps the app bundle's links and permissions.
    final (exe, args) = Platform.isMacOS
        ? ('ditto', ['-x', '-k', zip.path, dir.path])
        : Platform.isWindows
        ? ('tar', ['-xf', zip.path, '-C', dir.path])
        : ('unzip', ['-q', '-o', zip.path, '-d', dir.path]);
    final r = await ProcessSupervisor.instance.runBounded(
      exe,
      args,
      timeout: const Duration(minutes: 5),
      owner: const ProbeOwner('chrome-download'),
      label: 'unpack Chrome for Testing',
    );
    switch (r) {
      case Finished(:final code, :final stderr) when code != 0:
        throw StateError("couldn't unpack the browser: $stderr");
      case Finished():
        break;
      case TimedOut(:final kill) || Cancelled(:final kill):
        throw StateError(
          "couldn't unpack the browser: it took over 5 minutes (${kill is Ended ? 'stopped' : 'NOT closed: $kill'})",
        );
      case StartFailed(:final error):
        throw StateError("couldn't unpack the browser: $error");
      case Refused(:final reason):
        throw StateError("couldn't unpack the browser: $reason");
    }
    onProgress?.call(1);
    await loadDownloadedChrome();
    if (HeadlessBrowser.downloaded == null) throw StateError('the browser was unpacked but its program is missing');
    ok = true;
  } finally {
    if (zip.existsSync()) zip.deleteSync();
    // Half an unpacked browser would be taken for a whole one next time.
    if (!ok && unpacked.existsSync()) unpacked.deleteSync(recursive: true);
  }
}
