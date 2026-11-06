// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// The computers whose hardware we read.
enum HostOs { macos, windows, linux, other }

@immutable
final class Gpu {
  const Gpu({required this.name, this.vramBytes});
  final String name;

  /// Dedicated memory, when the system says; null for integrated GPUs and unknown ones.
  final int? vramBytes;

  @override
  bool operator ==(Object other) => other is Gpu && other.name == name && other.vramBytes == vramBytes;
  @override
  int get hashCode => Object.hash(name, vramBytes);
  @override
  String toString() => 'Gpu($name, $vramBytes)';
}

/// What a model can run on here: memory, GPUs and the free disk where models are kept.
@immutable
final class HardwareSpec {
  const HardwareSpec({
    required this.os,
    this.chip,
    this.memoryBytes,
    this.unifiedMemory = false,
    this.gpus = const [],
    this.freeDiskBytes,
  });

  final HostOs os;

  /// The processor's name ("Apple M2 Pro", "AMD Ryzen 9 7950X").
  final String? chip;
  final int? memoryBytes;

  /// Apple Silicon: the GPU uses system memory.
  final bool unifiedMemory;
  final List<Gpu> gpus;
  final int? freeDiskBytes;

  static const unknown = HardwareSpec(os: HostOs.other);

  /// The largest dedicated GPU memory, null without one.
  int? get vramBytes {
    int? best;
    for (final g in gpus) {
      final v = g.vramBytes;
      if (v != null && (best == null || v > best)) best = v;
    }
    return best;
  }

  /// The memory a model may take: about two thirds of unified memory on Apple Silicon (the system keeps the rest),
  /// the GPU's own memory where there is one, else half of RAM on the CPU.
  int? get usableModelBytes {
    final ram = memoryBytes;
    if (unifiedMemory) return ram == null ? null : (ram * 0.66).round();
    final vram = vramBytes;
    if (vram != null && vram > 0) return vram;
    return ram == null ? null : ram ~/ 2;
  }

  /// "This Mac: M2 Pro · 16 GB unified · 212 GB free".
  String get summary {
    final where = switch (os) {
      HostOs.macos => 'This Mac',
      _ => 'This computer',
    };
    final parts = <String>[
      if (chip != null) chip!.replaceFirst(RegExp(r'^Apple\s+'), ''),
      if (memoryBytes != null) '${gb(memoryBytes!)} GB ${unifiedMemory ? 'unified' : 'RAM'}',
      if (!unifiedMemory && vramBytes != null) '${gb(vramBytes!)} GB GPU',
      if (!unifiedMemory && vramBytes == null && gpus.isEmpty && memoryBytes != null) 'no GPU found',
      if (freeDiskBytes != null) '${gb(freeDiskBytes!)} GB free',
    ];
    return parts.isEmpty ? '$where: hardware unknown' : '$where: ${parts.join(' · ')}';
  }

  @override
  bool operator ==(Object other) =>
      other is HardwareSpec &&
      other.os == os &&
      other.chip == chip &&
      other.memoryBytes == memoryBytes &&
      other.unifiedMemory == unifiedMemory &&
      listEquals(other.gpus, gpus) &&
      other.freeDiskBytes == freeDiskBytes;
  @override
  int get hashCode => Object.hash(os, chip, memoryBytes, unifiedMemory, Object.hashAll(gpus), freeDiskBytes);
}

/// [bytes] in whole gigabytes (powers of 1024, as systems report memory), rounded.
int gb(int bytes) => (bytes / (1 << 30)).round();

const _gib = 1 << 30;
const _mib = 1 << 20;

// ------------------------------------------------------------------ macOS

/// `sysctl -n hw.memsize machdep.cpu.brand_string hw.optional.arm64`: one value per line.
({int? memory, String? chip, bool arm}) parseMacSysctl(String out) {
  final lines = out.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  final memory = lines.isEmpty ? null : int.tryParse(lines[0]);
  final chip = lines.length > 1 ? lines[1] : null;
  final arm = lines.length > 2 ? lines[2] == '1' : (chip?.startsWith('Apple') ?? false);
  return (memory: memory, chip: chip, arm: arm);
}

// ------------------------------------------------------------------ disk

/// `df -k <path>`: the free space of the filesystem holding path (the "Available" column of the last line).
int? parseDfFree(String out) {
  final lines = out.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
  if (lines.length < 2) return null;
  final header = lines.first.replaceAll('Mounted on', 'Mounted').trim().split(RegExp(r'\s+'));
  final avail = header.indexWhere((h) => h.toLowerCase().startsWith('avail'));
  final cols = lines.last.trim().split(RegExp(r'\s+'));
  // Filesystem names with spaces shift columns: count the "Available" column from the right when needed.
  final fromRight = avail < 0 ? 3 : header.length - avail;
  final i = cols.length - fromRight;
  if (i < 0 || i >= cols.length) return null;
  final kb = int.tryParse(cols[i]);
  return kb == null ? null : kb * 1024;
}

// ------------------------------------------------------------------ NVIDIA / AMD

/// `nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits` (MiB) or with the header and units.
List<Gpu> parseNvidiaSmi(String out) {
  final gpus = <Gpu>[];
  for (final raw in out.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.toLowerCase().startsWith('name')) continue;
    final at = line.lastIndexOf(',');
    if (at < 0) continue;
    final name = line.substring(0, at).trim();
    final mem = RegExp(r'(\d+)').firstMatch(line.substring(at + 1));
    final mib = mem == null ? null : int.tryParse(mem.group(1)!);
    if (name.isEmpty) continue;
    gpus.add(Gpu(name: name, vramBytes: mib == null ? null : mib * _mib));
  }
  return gpus;
}

/// `rocm-smi --showproductname --showmeminfo vram --json`: one card per `cardN` key.
List<Gpu> parseRocmSmi(String out) {
  final Object? decoded;
  try {
    decoded = jsonDecode(out);
  } on FormatException {
    return const [];
  }
  if (decoded is! Map<String, Object?>) return const [];
  final gpus = <Gpu>[];
  for (final MapEntry(:key, :value) in decoded.entries) {
    if (!key.startsWith('card') || value is! Map<String, Object?>) continue;
    String? name;
    int? vram;
    for (final MapEntry(key: k, value: v) in value.entries) {
      final lk = k.toLowerCase();
      if (name == null && (lk.contains('card series') || lk.contains('card model') || lk.contains('product name'))) {
        name = '$v';
      }
      if (lk.contains('vram total memory')) vram = int.tryParse('$v');
    }
    gpus.add(Gpu(name: name ?? 'AMD GPU', vramBytes: vram));
  }
  return gpus;
}

// ------------------------------------------------------------------ Linux

/// `/proc/meminfo`: MemTotal in kB.
int? parseMeminfo(String text) {
  final m = RegExp(r'^MemTotal:\s+(\d+)\s*kB', multiLine: true).firstMatch(text);
  return m == null ? null : int.parse(m.group(1)!) * 1024;
}

/// `/proc/cpuinfo`: the first "model name".
String? parseCpuinfoModel(String text) =>
    RegExp(r'^model name\s*:\s*(.+)$', multiLine: true).firstMatch(text)?.group(1)?.trim();

/// `lspci`: display controllers, by name only (memory isn't listed).
List<Gpu> parseLspciGpus(String out) => [
  for (final line in out.split('\n'))
    if (RegExp(r'(VGA compatible controller|3D controller|Display controller)').hasMatch(line))
      Gpu(name: line.split(RegExp(r'controller(\s*\[[0-9a-f]+\])?:\s*')).last.trim()),
];

// ------------------------------------------------------------------ Windows

/// PowerShell `Get-CimInstance ... | ConvertTo-Json` of `{TotalPhysicalMemory, Cpu, Gpus:[{Name, AdapterRAM}],
/// FreeBytes}` (see the Windows scan). AdapterRAM is a 32-bit field, so cards over 4 GB read as 4 GB or less:
/// nvidia-smi's answer wins when there is one.
({int? memory, String? chip, List<Gpu> gpus, int? free}) parseWindowsCim(String out) {
  final Object? d;
  try {
    d = jsonDecode(out);
  } on FormatException {
    return (memory: null, chip: null, gpus: const [], free: null);
  }
  if (d is! Map<String, Object?>) return (memory: null, chip: null, gpus: const [], free: null);
  int? asInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v');
  final raw = d['Gpus'];
  final list = raw is List ? raw : (raw is Map ? <Object?>[raw] : const <Object?>[]);
  final gpus = <Gpu>[
    for (final g in list)
      if (g is Map && g['Name'] is String)
        Gpu(name: (g['Name'] as String).trim(), vramBytes: _plausibleVram(asInt(g['AdapterRAM']))),
  ];
  return (
    memory: asInt(d['TotalPhysicalMemory']),
    chip: (d['Cpu'] as String?)?.trim(),
    gpus: gpus,
    free: asInt(d['FreeBytes']),
  );
}

/// AdapterRAM under 512 MB is the shared aperture of an integrated GPU, not memory a model can use.
int? _plausibleVram(int? v) => v == null || v < 512 * _mib ? null : v;

/// Merges [better] (nvidia-smi / rocm-smi) over [names] (lspci / CIM): same-vendor cards take the measured memory.
List<Gpu> mergeGpus(List<Gpu> names, List<Gpu> better) {
  if (better.isEmpty) return names;
  final rest = [
    for (final n in names)
      if (!better.any((b) => _vendor(b.name) == _vendor(n.name))) n,
  ];
  return [...better, ...rest];
}

String _vendor(String name) {
  final n = name.toLowerCase();
  if (n.contains('nvidia') || n.contains('geforce') || n.contains('rtx') || n.contains('quadro')) return 'nvidia';
  if (n.contains('amd') || n.contains('radeon') || n.contains('ati')) return 'amd';
  if (n.contains('intel')) return 'intel';
  return n;
}

/// Bytes from a size the user can read ("16 GB").
int gibBytes(num g) => (g * _gib).round();
