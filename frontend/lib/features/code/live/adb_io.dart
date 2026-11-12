// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/process/supervisor.dart';
import 'app_view.dart';

/// The Android SDK's tools on this computer: adb and the emulator, from ANDROID_HOME / ANDROID_SDK_ROOT, the usual
/// SDK folders, or the PATH. Nothing is downloaded (an Android SDK comes with Android Studio).
abstract final class AndroidSdk {
  static String? _adb, _emulator;
  static var _looked = false;

  static List<String> get _roots {
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
    return [
      ?env['ANDROID_HOME'],
      ?env['ANDROID_SDK_ROOT'],
      if (Platform.isMacOS) '$home/Library/Android/sdk',
      if (Platform.isLinux) '$home/Android/Sdk',
      if (Platform.isWindows && env['LOCALAPPDATA'] != null) '${env['LOCALAPPDATA']}\\Android\\Sdk',
    ];
  }

  static void _look() {
    if (_looked) return;
    _looked = true;
    final exe = Platform.isWindows ? '.exe' : '';
    final sep = Platform.isWindows ? '\\' : '/';
    for (final root in _roots) {
      _adb ??= _exists('$root${sep}platform-tools${sep}adb$exe');
      _emulator ??= _exists('$root${sep}emulator${sep}emulator$exe');
    }
    for (final dir in (Platform.environment['PATH'] ?? '').split(Platform.isWindows ? ';' : ':')) {
      if (dir.isEmpty) continue;
      _adb ??= _exists('$dir${sep}adb$exe');
      _emulator ??= _exists('$dir${sep}emulator$exe');
    }
  }

  static String? _exists(String p) => File(p).existsSync() ? p : null;

  static String? get adb {
    _look();
    return Platform.environment['EVERYAI_ADB'] ?? _adb;
  }

  static String? get emulator {
    _look();
    return _emulator;
  }

  static String get _need =>
      adb ?? (throw const AppError('No adb here: install Android Studio (or the SDK platform-tools).'));

  /// `adb [-s serial] args`, its output (throws [AppError] on failure).
  /// [duringQuit] lets a goodbye (`emu kill`) run while the app quits.
  static Future<String> run(
    List<String> args, {
    String? serial,
    Duration timeout = const Duration(seconds: 60),
    bool duringQuit = false,
  }) async {
    final r = await runBytes(args, serial: serial, timeout: timeout, duringQuit: duringQuit);
    return utf8.decode(r, allowMalformed: true);
  }

  static Future<Uint8List> runBytes(
    List<String> args, {
    String? serial,
    Duration timeout = const Duration(seconds: 60),
    bool duringQuit = false,
  }) async {
    final r = await ProcessSupervisor.instance.runBounded(
      _need,
      [
        if (serial != null) ...['-s', serial],
        ...args,
      ],
      timeout: timeout,
      owner: const ProbeOwner('adb'),
      stderrEncoding: utf8,
      duringQuit: duringQuit,
      label: 'adb ${args.take(3).join(' ')}',
    );
    switch (r) {
      case Finished(:final code, :final stderr, :final stdoutBytes):
        if (code != 0) {
          final why = stderr.trim().split('\n').where((l) => l.trim().isNotEmpty).lastOrNull ?? 'exit $code';
          throw AppError('adb ${args.first} failed: $why');
        }
        return stdoutBytes;
      case TimedOut(:final kill) || Cancelled(:final kill):
        throw AppError(
          'adb ${args.first} took longer than ${timeout.inSeconds} s and was '
          '${kill is Ended ? 'stopped' : 'NOT closed ($kill)'}',
        );
      case StartFailed(:final error):
        throw AppError('adb ${args.first} could not start: $error');
      case Refused(:final reason):
        throw AppError('adb ${args.first} could not start: $reason');
    }
  }

  /// [args] as one `adb shell` command line, each quoted for the device's shell.
  static Future<String> shell(String serial, List<String> args, {Duration timeout = const Duration(seconds: 60)}) =>
      run(['shell', args.map(shellQuote).join(' ')], serial: serial, timeout: timeout);
}

/// [s] for a POSIX shell (single quotes; plain words stay as they are).
String shellQuote(String s) {
  if (s.isNotEmpty && RegExp(r'^[A-Za-z0-9_./:=@%+,-]+$').hasMatch(s)) return s;
  return "'${s.replaceAll("'", r"'\''")}'";
}
