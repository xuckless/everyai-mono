// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:io';

import '../../../core/process/supervisor.dart';
import '../git/git_service.dart';
import 'axe_pin.dart';
import 'verified_download_io.dart';

String? _downloaded;

/// Where the downloaded AXe lives (one folder per pinned version).
Future<String> _home() async => '${await GitService.dataDir()}/tools/axe-$axeVersion';

String? axePath() {
  final set = Platform.environment['EVERYAI_AXE'];
  if (set != null && File(set).existsSync()) return set;
  if (_downloaded != null && File(_downloaded!).existsSync()) return _downloaded;
  for (final dir in [...(Platform.environment['PATH'] ?? '').split(':'), '/opt/homebrew/bin', '/usr/local/bin']) {
    if (dir.isNotEmpty && File('$dir/axe').existsSync()) return '$dir/axe';
  }
  return null;
}

Future<String> ensureAxe({void Function(double progress)? onProgress}) async {
  if (axePath() case final p?) return p;
  try {
    final exe = '${await _home()}/axe';
    if (File(exe).existsSync()) return _downloaded = exe;
  } on Object {
    // No app data folder (tests).
  }
  return installAxe(onProgress: onProgress);
}

/// One download at a time (the agent and the Preview may both ask).
Future<String>? _installing;

Future<String> installAxe({void Function(double progress)? onProgress}) =>
    _installing ??= _install(onProgress).whenComplete(() => _installing = null);

Future<String> _install(void Function(double progress)? onProgress) async {
  if (!Platform.isMacOS) throw UnsupportedError('iOS Simulators need macOS');
  final home = await _home();
  final dir = Directory(home)..createSync(recursive: true);
  final archive = File('${dir.path}/axe.tar.gz.part');
  final exe = '${dir.path}/axe';
  var ok = false;
  try {
    await downloadVerified(Uri.parse(axeUrl), axeSha256, archive, onProgress: (p) => onProgress?.call(p * 0.95));
    final r = await ProcessSupervisor.instance.runBounded(
      'tar',
      ['-xzf', archive.path, '-C', dir.path],
      timeout: const Duration(minutes: 2),
      owner: const ProbeOwner('axe-install'),
      label: 'unpack AXe',
    );
    switch (r) {
      case Finished(:final code, :final stderr) when code != 0:
        throw StateError("couldn't unpack AXe: $stderr");
      case Finished():
        break;
      case TimedOut(:final kill) || Cancelled(:final kill):
        throw StateError(
          "couldn't unpack AXe: it took over 2 minutes (${kill is Ended ? 'stopped' : 'NOT closed: $kill'})",
        );
      case StartFailed(:final error):
        throw StateError("couldn't unpack AXe: $error");
    }
    if (!File(exe).existsSync()) throw StateError('AXe was unpacked but its program is missing');
    ok = true;
  } finally {
    if (archive.existsSync()) archive.deleteSync();
    if (!ok && File(exe).existsSync()) File(exe).deleteSync();
  }
  onProgress?.call(1);
  return _downloaded = exe;
}
