// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'hardware.dart';

/// What a model in a pack is for.
enum PackRole { chat, code, vision }

@immutable
final class PackModel {
  const PackModel({
    required this.roles,
    required this.ollama,
    required this.sizeGb,
    required this.minMemoryGb,
    this.context,
    this.tools = false,
    this.vision = false,
  });

  final Set<PackRole> roles;

  /// The Ollama tag (`qwen3.5:9b`).
  final String ollama;
  final double sizeGb;
  final double minMemoryGb;
  final int? context;
  final bool tools;
  final bool vision;
}

/// A sized starter pack: one model per role (a model may cover several).
@immutable
final class Pack {
  const Pack({required this.id, required this.label, required this.blurb, required this.models});

  /// `light`, `balanced` or `best`.
  final String id;
  final String label;
  final String blurb;
  final List<PackModel> models;

  /// The download, all models together.
  double get sizeGb => models.fold(0.0, (s, m) => s + m.sizeGb);

  /// The memory the largest model needs (one runs at a time).
  double get minMemoryGb => models.fold(0.0, (s, m) => m.minMemoryGb > s ? m.minMemoryGb : s);

  List<String> get tags => [for (final m in models) m.ollama];
}

/// The model catalogue (`assets/local_models.json`, refreshed from the repo).
@immutable
final class Catalogue {
  const Catalogue({required this.version, required this.packs});
  final int version;
  final List<Pack> packs;
}

/// [raw] as a catalogue, or null when its shape is wrong (a refreshed copy that doesn't parse is never used).
Catalogue? parseCatalogue(String raw) {
  try {
    final d = jsonDecode(raw);
    if (d is! Map<String, Object?>) return null;
    final version = d['version'];
    final packs = d['packs'];
    if (version is! int || packs is! List || packs.isEmpty) return null;
    final out = <Pack>[];
    for (final p in packs) {
      if (p is! Map<String, Object?>) return null;
      final id = p['id'], label = p['label'], models = p['models'];
      if (id is! String || label is! String || models is! List || models.isEmpty) return null;
      final ms = <PackModel>[];
      for (final m in models) {
        if (m is! Map<String, Object?>) return null;
        final tag = m['ollama'], size = m['size_gb'], min = m['min_memory_gb'], roles = m['roles'];
        if (tag is! String || !_tag.hasMatch(tag) || size is! num || min is! num || roles is! List) return null;
        final rs = <PackRole>{for (final r in roles) ?PackRole.values.where((v) => v.name == r).firstOrNull};
        if (rs.isEmpty) return null;
        ms.add(
          PackModel(
            roles: rs,
            ollama: tag,
            sizeGb: size.toDouble(),
            minMemoryGb: min.toDouble(),
            context: (m['context'] as num?)?.toInt(),
            tools: m['tools'] == true,
            vision: m['vision'] == true,
          ),
        );
      }
      out.add(Pack(id: id, label: label, blurb: p['blurb'] as String? ?? '', models: ms));
    }
    return Catalogue(version: version, packs: out);
  } on Object {
    return null;
  }
}

/// An Ollama tag: `name[:tag]`, up to two path parts (`hf.co/org/model`), nothing a shell or URL could misread.
final _tag = RegExp(r'^[a-z0-9][a-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*){0,2}(:[A-Za-z0-9][A-Za-z0-9._-]*)?$');

/// How a pack fits this computer.
@immutable
final class PackFit {
  const PackFit({required this.pack, required this.fits, required this.best, this.reason});
  final Pack pack;
  final bool fits;

  /// The largest pack that fits (the one we suggest).
  final bool best;

  /// Why it doesn't fit, in plain words.
  final String? reason;
}

/// Every pack against [spec]: a pack fits when its largest model fits the usable model memory and the download fits
/// the free disk. Unknown hardware fits everything but marks only the smallest as best.
List<PackFit> fitPacks(List<Pack> packs, HardwareSpec spec) {
  final usable = spec.usableModelBytes;
  final disk = spec.freeDiskBytes;
  final fits = <bool>[];
  final reasons = <String?>[];
  for (final p in packs) {
    String? reason;
    if (usable != null && gibBytes(p.minMemoryGb) > usable) {
      reason = 'Needs about ${p.minMemoryGb.round()} GB for models; ${gb(usable)} GB usable here';
    } else if (disk != null && gibBytes(p.sizeGb + 2) > disk) {
      reason = 'Needs ${p.sizeGb.ceil()} GB of disk; ${gb(disk)} GB free';
    }
    fits.add(reason == null);
    reasons.add(reason);
  }
  var best = -1;
  if (usable == null) {
    best = fits.indexOf(true);
  } else {
    for (var i = 0; i < packs.length; i++) {
      if (fits[i] && (best < 0 || packs[i].minMemoryGb > packs[best].minMemoryGb)) best = i;
    }
  }
  return [
    for (var i = 0; i < packs.length; i++) PackFit(pack: packs[i], fits: fits[i], best: i == best, reason: reasons[i]),
  ];
}
