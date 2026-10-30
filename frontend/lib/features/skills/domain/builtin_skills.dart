import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// A skill bundled with the app (`assets/skills/<name>/`): its files by
/// relative path.
final class BuiltinSkill {
  BuiltinSkill(this.name, this.files);

  final String name;
  final Map<String, List<int>> files;

  /// Changes whenever any bundled file does, so an app update replaces the
  /// copy installed earlier.
  late final String digest = _digest();

  String _digest() {
    final all = BytesBuilder();
    for (final path in files.keys.toList()..sort()) {
      all.add(utf8.encode('$path\u0000'));
      all.add(files[path]!);
      all.addByte(0);
    }
    return sha256.convert(all.takeBytes()).toString();
  }
}

const builtinSkillsAssetDir = 'assets/skills/';

/// Reads every bundled skill from [bundle], sorted by name.
Future<List<BuiltinSkill>> loadBuiltinSkills([AssetBundle? bundle]) async {
  final b = bundle ?? rootBundle;
  final manifest = await AssetManifest.loadFromAssetBundle(b);
  final byName = <String, Map<String, List<int>>>{};
  for (final asset in manifest.listAssets()) {
    final path = Uri.decodeFull(asset);
    if (!path.startsWith(builtinSkillsAssetDir)) continue;
    final rest = path.substring(builtinSkillsAssetDir.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) continue;
    final data = await b.load(asset);
    byName.putIfAbsent(rest.substring(0, slash), () => {})[rest.substring(slash + 1)] = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  }
  return [for (final n in byName.keys.toList()..sort()) BuiltinSkill(n, byName[n]!)];
}
