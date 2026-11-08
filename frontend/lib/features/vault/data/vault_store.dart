import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/vault_format.dart';

/// The vault's files in one folder (app data `vault/`): `vault.json`,
/// `items/<id>.json`, `manifest.json` ({bytes, signature}) and `seen` (the
/// highest manifest version this device verified, for rollback checks).
/// Writes go to a temp file and are renamed over, so a crash leaves the old
/// file. Tools can't read this folder (`exfil.dart`).
final class VaultStore {
  VaultStore(this.dir);
  final Directory dir;

  File get _header => File('${dir.path}/vault.json');
  File get _manifest => File('${dir.path}/manifest.json');
  File get _seen => File('${dir.path}/seen');
  File _item(String id) => File('${dir.path}/items/${_safe(id)}.json');

  static String _safe(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id)) throw VaultFormatError('item id "$id"');
    return id;
  }

  Future<void> _write(File f, String text) async {
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(f.path);
  }

  Future<VaultHeader?> header() async =>
      await _header.exists() ? VaultHeader.fromJson(jsonDecode(await _header.readAsString())) : null;

  Future<void> saveHeader(VaultHeader h) => _write(_header, jsonEncode(h.toJson()));

  Future<VaultItem?> item(String id) async {
    final f = _item(id);
    return await f.exists() ? VaultItem.fromJson(jsonDecode(await f.readAsString())) : null;
  }

  Future<void> saveItem(VaultItem item) => _write(_item(item.id), jsonEncode(item.toJson()));

  Future<void> deleteItem(String id) async {
    final f = _item(id);
    if (await f.exists()) await f.delete();
  }

  Future<({Uint8List bytes, Uint8List signature})?> manifest() async {
    if (!await _manifest.exists()) return null;
    final j = jsonDecode(await _manifest.readAsString());
    if (j is! Map || j['bytes'] is! String || j['signature'] is! String) throw const VaultFormatError('manifest.json');
    return (bytes: base64.decode(j['bytes'] as String), signature: base64.decode(j['signature'] as String));
  }

  Future<void> saveManifest(Uint8List bytes, Uint8List signature) =>
      _write(_manifest, jsonEncode({'bytes': base64.encode(bytes), 'signature': base64.encode(signature)}));

  Future<int> seenVersion() async => await _seen.exists() ? int.tryParse(await _seen.readAsString()) ?? 0 : 0;

  Future<void> saveSeen(int version) => _write(_seen, '$version');
}
