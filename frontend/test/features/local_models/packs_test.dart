import 'dart:io';

import 'package:every_ai/features/local_models/domain/hardware.dart';
import 'package:every_ai/features/local_models/domain/packs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final bundled = parseCatalogue(File('assets/local_models.json').readAsStringSync());

  test('the bundled catalogue parses: light, balanced, best, each with chat and code', () {
    expect(bundled, isNotNull);
    expect(bundled!.packs.map((p) => p.id), ['light', 'balanced', 'best']);
    for (final p in bundled.packs) {
      final roles = {for (final m in p.models) ...m.roles};
      expect(roles, containsAll([PackRole.chat, PackRole.code]), reason: p.id);
      for (final m in p.models) {
        expect(m.tools, isTrue, reason: m.ollama);
        expect(m.minMemoryGb, greaterThanOrEqualTo(m.sizeGb), reason: m.ollama);
      }
    }
    // Sizes grow with the packs.
    final sizes = [for (final p in bundled.packs) p.minMemoryGb];
    expect(sizes, orderedEquals([...sizes]..sort()));
  });

  test('a catalogue with a wrong shape or an odd tag is refused', () {
    expect(parseCatalogue('[]'), isNull);
    expect(parseCatalogue('{"version": 1, "packs": []}'), isNull);
    const bad =
        '{"version":2,"packs":[{"id":"x","label":"X","models":[{"roles":["chat"],"ollama":"qwen; rm -rf /","size_gb":1,"min_memory_gb":2}]}]}';
    expect(parseCatalogue(bad), isNull);
    const noRole =
        '{"version":2,"packs":[{"id":"x","label":"X","models":[{"roles":["dance"],"ollama":"qwen3.5:4b","size_gb":1,"min_memory_gb":2}]}]}';
    expect(parseCatalogue(noRole), isNull);
    const good =
        '{"version":2,"packs":[{"id":"x","label":"X","models":[{"roles":["chat"],"ollama":"hf.co/org/model:q4","size_gb":1,"min_memory_gb":2}]}]}';
    expect(parseCatalogue(good)?.packs.single.tags, ['hf.co/org/model:q4']);
  });

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

  test('unknown hardware: everything allowed, the smallest suggested', () {
    final fits = fitPacks(bundled!.packs, HardwareSpec.unknown);
    expect(fits.every((f) => f.fits), isTrue);
    expect(fits.where((f) => f.best).single.pack.id, 'light');
  });
}
