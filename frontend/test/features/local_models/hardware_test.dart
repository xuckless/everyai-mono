import 'package:every_ai/features/local_models/data/hardware_scan.dart';
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

    test('nvidia-smi with and without units', () {
      expect(parseNvidiaSmi('NVIDIA GeForce RTX 4090, 24564\nNVIDIA RTX A2000, 6138\n'), [
        const Gpu(name: 'NVIDIA GeForce RTX 4090', vramBytes: 24564 << 20),
        const Gpu(name: 'NVIDIA RTX A2000', vramBytes: 6138 << 20),
      ]);
      expect(
        parseNvidiaSmi('name, memory.total [MiB]\nNVIDIA GeForce RTX 3060, 12288 MiB\n').single.vramBytes,
        12288 << 20,
      );
    });

    test('rocm-smi JSON', () {
      const out = '{"card0": {"Card series": "Radeon RX 7900 XTX", "VRAM Total Memory (B)": "25753026560"}}';
      expect(parseRocmSmi(out), [const Gpu(name: 'Radeon RX 7900 XTX', vramBytes: 25753026560)]);
      expect(parseRocmSmi('not json'), isEmpty);
    });

    test('/proc/meminfo, cpuinfo and lspci', () {
      expect(parseMeminfo('MemTotal:       32768000 kB\nMemFree: 1 kB\n'), 32768000 * 1024);
      expect(
        parseCpuinfoModel('processor\t: 0\nmodel name\t: AMD Ryzen 9 7950X 16-Core Processor\n'),
        'AMD Ryzen 9 7950X 16-Core Processor',
      );
      final gpus = parseLspciGpus(
        '00:02.0 VGA compatible controller: Intel Corporation Alder Lake-P GT2 [Iris Xe Graphics] (rev 0c)\n'
        '01:00.0 3D controller: NVIDIA Corporation GA107M [GeForce RTX 3050 Mobile] (rev a1)\n'
        '00:1f.3 Audio device: Intel Corporation\n',
      );
      expect(gpus.map((g) => g.name), [
        'Intel Corporation Alder Lake-P GT2 [Iris Xe Graphics] (rev 0c)',
        'NVIDIA Corporation GA107M [GeForce RTX 3050 Mobile] (rev a1)',
      ]);
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
    test('Apple Silicon: two thirds of unified memory', () {
      const spec = HardwareSpec(
        os: HostOs.macos,
        chip: 'Apple M2 Pro',
        memoryBytes: 16 << 30,
        unifiedMemory: true,
        freeDiskBytes: 212 << 30,
      );
      expect(gb(spec.usableModelBytes!), 11);
      expect(spec.summary, 'This Mac: M2 Pro · 16 GB unified · 212 GB free');
    });

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

  test('the macOS scan reads sysctl and df, and survives a failing part', () async {
    final runs = <String>[];
    final spec = await scanHardwareWith(
      os: HostOs.macos,
      diskPath: '/Users/me/.ollama/models',
      readFile: (_) async => null,
      run: (exe, args) async {
        runs.add('$exe ${args.join(' ')}');
        return switch (args.last) {
          'hw.memsize' => (code: 0, out: '17179869184\n'),
          'machdep.cpu.brand_string' => (code: 0, out: 'Apple M2 Pro\n'),
          'hw.optional.arm64' => (code: 0, out: '1\n'),
          _ => null,
        };
      },
    );
    expect(spec.memoryBytes, 17179869184);
    expect(spec.unifiedMemory, isTrue);
    expect(spec.chip, 'Apple M2 Pro');
    expect(spec.freeDiskBytes, isNull);
    expect(runs, contains('/bin/df -k /Users/me/.ollama/models'));
  });

  test('the Linux scan merges lspci with nvidia-smi', () async {
    final spec = await scanHardwareWith(
      os: HostOs.linux,
      diskPath: '/home/me',
      readFile: (p) async => p == '/proc/meminfo' ? 'MemTotal: 33554432 kB\n' : null,
      run: (exe, args) async => switch (exe) {
        'nvidia-smi' => (code: 0, out: 'NVIDIA GeForce RTX 3090, 24576\n'),
        'lspci' => (code: 0, out: '01:00.0 VGA compatible controller: NVIDIA Corporation GA102 [GeForce RTX 3090]\n'),
        _ => null,
      },
    );
    expect(spec.memoryBytes, 32 << 30);
    expect(spec.gpus.single.vramBytes, 24576 << 20);
  });

  test('the Windows script asks for the models drive', () {
    expect(windowsCimScript('D'), contains("Get-PSDrive -Name 'D'"));
  });
}
