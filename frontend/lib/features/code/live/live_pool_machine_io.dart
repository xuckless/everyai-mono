// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import '../../../core/process/supervisor.dart';

/// This machine's RAM (GB) and cores, or null when the RAM can't be read.
Future<({double ramGb, int cores})?> readMachine() async {
  final cores = Platform.numberOfProcessors;
  int? bytes;
  if (Platform.isMacOS) {
    final r = await ProcessSupervisor.instance.runBounded(
      '/usr/sbin/sysctl',
      ['-n', 'hw.memsize'],
      timeout: const Duration(seconds: 5),
      owner: const ProbeOwner('pool'),
      label: 'sysctl hw.memsize',
    );
    if (r case Finished(code: 0, :final stdout)) bytes = int.tryParse(stdout.trim());
  } else if (Platform.isLinux) {
    try {
      final m = RegExp(r'MemTotal:\s+(\d+)\s*kB').firstMatch(await File('/proc/meminfo').readAsString());
      if (m != null) bytes = int.parse(m.group(1)!) * 1024;
    } on FileSystemException {
      bytes = null;
    }
  }
  if (bytes == null) return null;
  return (ramGb: bytes / (1024 * 1024 * 1024), cores: cores);
}
