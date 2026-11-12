import 'dart:io';

import 'package:every_ai/features/local_models/domain/hardware.dart';
import 'package:every_ai/features/local_models/domain/packs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final bundled = parseCatalogue(File('assets/local_models.json').readAsStringSync());

  test('a 16 GB Mac: Balanced fits best, Best is greyed with the reason', () {
    const spec = HardwareSpec(os: HostOs.macos, memoryBytes: 16 << 30, unifiedMemory: true, freeDiskBytes: 212 << 30);
    final fits = fitPacks(bundled!.packs, spec);
    expect(
      {for (final f in fits) f.pack.id: (f.fits, f.best)},
      {'light': (true, false), 'balanced': (true, true), 'best': (false, false)},
    );
    expect(fits.last.reason, contains('11 GB usable'));
  });

  test('a 24 GB GPU takes Best; a full disk refuses it', () {
    const gpu = HardwareSpec(
      os: HostOs.linux,
      memoryBytes: 32 << 30,
      gpus: [Gpu(name: 'RTX 4090', vramBytes: 24 << 30)],
      freeDiskBytes: 500 << 30,
    );
    expect(fitPacks(bundled!.packs, gpu).where((f) => f.best).single.pack.id, 'best');
    const full = HardwareSpec(
      os: HostOs.linux,
      memoryBytes: 32 << 30,
      gpus: [Gpu(name: 'RTX 4090', vramBytes: 24 << 30)],
      freeDiskBytes: 10 << 30,
    );
    final fits = fitPacks(bundled.packs, full);
    expect(fits.last.fits, isFalse);
    expect(fits.last.reason, contains('of disk'));
    expect(fits.where((f) => f.best).single.pack.id, 'balanced');
  });
}
