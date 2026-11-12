import 'package:every_ai/features/local_models/domain/hardware.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parsers', () {
    test('df -k: the Available column, also with a name containing spaces', () {
      const mac = '''
Filesystem     1024-blocks      Used Available Capacity iused      ifree %iused  Mounted on
/dev/disk3s5    971350180 747720960 222301812    78% 6515201 2223018120    0%   /System/Volumes/Data
''';
      expect(parseDfFree(mac), 222301812 * 1024);
      const linux = '''
Filesystem     1K-blocks     Used Available Use% Mounted on
/dev/nvme0n1p2 490617880 98765432 366789012  22% /
''';
      expect(parseDfFree(linux), 366789012 * 1024);
      expect(parseDfFree(''), isNull);
    });

    test('Windows CIM: one GPU object or a list; a tiny AdapterRAM is no VRAM', () {
      final one = parseWindowsCim(
        '{"TotalPhysicalMemory":34359738368,"Cpu":"Intel(R) Core(TM) i7 ","Gpus":{"Name":"Intel(R) UHD","AdapterRAM":134217728},"FreeBytes":500000000000}',
      );
      expect(one.memory, 34359738368);
      expect(one.chip, 'Intel(R) Core(TM) i7');
      expect(one.gpus, [const Gpu(name: 'Intel(R) UHD')]);
      expect(one.free, 500000000000);
      final two = parseWindowsCim('{"Gpus":[{"Name":"NVIDIA GeForce RTX 4070","AdapterRAM":4293918720}]}');
      expect(two.gpus.single.vramBytes, 4293918720);
      // nvidia-smi's measure wins over the 32-bit CIM field.
      final merged = mergeGpus(two.gpus, parseNvidiaSmi('NVIDIA GeForce RTX 4070, 12282'));
      expect(merged.single.vramBytes, 12282 << 20);
    });
  });

  group('usable memory and the summary', () {
    test('a GPU uses its own memory; none means half the RAM', () {
      const withGpu = HardwareSpec(
        os: HostOs.linux,
        memoryBytes: 64 << 30,
        gpus: [Gpu(name: 'RTX 4090', vramBytes: 24 << 30)],
      );
      expect(withGpu.usableModelBytes, 24 << 30);
      expect(withGpu.summary, 'This computer: 64 GB RAM · 24 GB GPU');
      const cpu = HardwareSpec(os: HostOs.windows, memoryBytes: 16 << 30);
      expect(cpu.usableModelBytes, 8 << 30);
      expect(cpu.summary, contains('no GPU found'));
      expect(HardwareSpec.unknown.usableModelBytes, isNull);
    });
  });
}
