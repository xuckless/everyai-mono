// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../domain/hardware.dart';

/// Runs a program and returns its exit code and standard output; null when it couldn't start (not installed).
typedef LocalRun = Future<({int code, String out})?> Function(String executable, List<String> args);

/// Reads a text file, null when it can't.
typedef ReadText = Future<String?> Function(String path);

/// The PowerShell that prints one JSON object for [parseWindowsCim]. [drive] is the letter models are kept on.
String windowsCimScript(String drive) =>
    r'$cs=Get-CimInstance Win32_ComputerSystem;'
    r'$cpu=(Get-CimInstance Win32_Processor|Select-Object -First 1).Name;'
    r'$g=@(Get-CimInstance Win32_VideoController|Select-Object Name,AdapterRAM);'
    "\$f=(Get-PSDrive -Name '$drive').Free;"
    r'[pscustomobject]@{TotalPhysicalMemory=$cs.TotalPhysicalMemory;Cpu=$cpu;Gpus=$g;FreeBytes=$f}'
    '|ConvertTo-Json -Depth 3 -Compress';

/// The hardware of this [os], read with [run] and [readFile]; [diskPath] is where models go (its free space counts).
/// Each part that fails is left unknown rather than failing the scan.
Future<HardwareSpec> scanHardwareWith({
  required HostOs os,
  required LocalRun run,
  required ReadText readFile,
  required String diskPath,
}) async {
  Future<String?> out(String exe, List<String> args) async {
    try {
      final r = await run(exe, args);
      return r != null && r.code == 0 ? r.out : null;
    } on Object {
      return null;
    }
  }

  switch (os) {
    case HostOs.macos:
      final mem = int.tryParse((await out('/usr/sbin/sysctl', ['-n', 'hw.memsize']))?.trim() ?? '');
      final chip = (await out('/usr/sbin/sysctl', ['-n', 'machdep.cpu.brand_string']))?.trim();
      final arm = (await out('/usr/sbin/sysctl', ['-n', 'hw.optional.arm64']))?.trim() == '1';
      final df = await out('/bin/df', ['-k', diskPath]);
      return HardwareSpec(
        os: os,
        chip: chip == null || chip.isEmpty ? null : chip,
        memoryBytes: mem,
        unifiedMemory: arm || (chip?.startsWith('Apple') ?? false),
        gpus: arm ? [Gpu(name: chip ?? 'Apple GPU')] : const [],
        freeDiskBytes: df == null ? null : parseDfFree(df),
      );
    case HostOs.linux:
      final meminfo = await readFile('/proc/meminfo');
      final cpuinfo = await readFile('/proc/cpuinfo');
      final nvidia = await out('nvidia-smi', ['--query-gpu=name,memory.total', '--format=csv,noheader,nounits']);
      final rocm = await out('rocm-smi', ['--showproductname', '--showmeminfo', 'vram', '--json']);
      final lspci = await out('lspci', const []);
      final df = await out('df', ['-k', diskPath]);
      return HardwareSpec(
        os: os,
        chip: cpuinfo == null ? null : parseCpuinfoModel(cpuinfo),
        memoryBytes: meminfo == null ? null : parseMeminfo(meminfo),
        gpus: mergeGpus(lspci == null ? const [] : parseLspciGpus(lspci), [
          if (nvidia != null) ...parseNvidiaSmi(nvidia),
          if (rocm != null) ...parseRocmSmi(rocm),
        ]),
        freeDiskBytes: df == null ? null : parseDfFree(df),
      );
    case HostOs.windows:
      final drive = RegExp(r'^([A-Za-z]):').firstMatch(diskPath)?.group(1) ?? 'C';
      final cim = await out('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', windowsCimScript(drive)]);
      final nvidia = await out('nvidia-smi', ['--query-gpu=name,memory.total', '--format=csv,noheader,nounits']);
      final parsed = cim == null ? null : parseWindowsCim(cim);
      return HardwareSpec(
        os: os,
        chip: parsed?.chip,
        memoryBytes: parsed?.memory,
        gpus: mergeGpus(parsed?.gpus ?? const [], nvidia == null ? const [] : parseNvidiaSmi(nvidia)),
        freeDiskBytes: parsed?.free,
      );
    case HostOs.other:
      return HardwareSpec.unknown;
  }
}
