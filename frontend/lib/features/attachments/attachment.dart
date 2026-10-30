import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/domain/model_catalog.dart';

/// What a file is, as far as models are concerned. Text and code go to every
/// model (inlined as text); the rest needs the matching input modality.
enum AttachmentKind {
  text('File', null, 256 * 1024),
  image('Image', 'image', 5 * 1024 * 1024),
  pdf('PDF', 'file', 20 * 1024 * 1024),
  audio('Audio', 'audio', 20 * 1024 * 1024),
  other('File', null, 20 * 1024 * 1024);

  const AttachmentKind(this.label, this.modality, this.maxBytes);
  final String label;

  /// The catalog `input_modalities` entry a model needs (null: text, or never).
  final String? modality;
  final int maxBytes;
}

/// All attachments of one message together.
const maxMessageBytes = 25 * 1024 * 1024;

/// A file picked or dropped into a composer, before it is sent.
@immutable
final class Attachment {
  const Attachment({required this.id, required this.name, required this.mime, required this.kind, required this.bytes});

  final String id;
  final String name;
  final String mime;
  final AttachmentKind kind;
  final Uint8List bytes;

  int get size => bytes.length;

  /// Decoded contents of a text file.
  String get text => utf8.decode(bytes, allowMalformed: true);

  String get dataUrl => 'data:$mime;base64,${base64Encode(bytes)}';

  /// Reads [name] + [bytes] into an attachment, or explains why it can't be one.
  static ({Attachment? attachment, String? error}) from({
    required String id,
    required String name,
    required Uint8List bytes,
    String? mime,
  }) {
    final kind = kindOf(name, bytes, mime: mime);
    if (bytes.length > kind.maxBytes) {
      return (
        attachment: null,
        error: '$name is too large (${formatBytes(bytes.length)}; limit ${formatBytes(kind.maxBytes)}).',
      );
    }
    return (
      attachment: Attachment(id: id, name: name, mime: mimeOf(name, kind, mime), kind: kind, bytes: bytes),
      error: null,
    );
  }

  /// Why [model] can't take this file in Chat, or null when it can.
  String? unsupportedBy(ModelSpec model) {
    if (model.accepts(kind)) return null;
    return switch (kind) {
      AttachmentKind.other => "This type of file can't be sent to a model",
      _ => '${model.name} can\'t read ${kind == AttachmentKind.image ? 'images' : '${kind.label}s'}',
    };
  }
}

const _imageTypes = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
};
const _audioTypes = {'mp3': 'audio/mpeg', 'wav': 'audio/wav'};

/// Extensions read as text for every model (the native picker allows these).
const textExtensions = [
  'txt',
  'md',
  'markdown',
  'rst',
  'csv',
  'tsv',
  'json',
  'jsonl',
  'yaml',
  'yml',
  'toml',
  'xml',
  'html',
  'htm',
  'css',
  'scss',
  'js',
  'jsx',
  'mjs',
  'ts',
  'tsx',
  'dart',
  'py',
  'rb',
  'go',
  'rs',
  'zig',
  'c',
  'h',
  'cc',
  'cpp',
  'hpp',
  'm',
  'mm',
  'swift',
  'kt',
  'kts',
  'java',
  'scala',
  'cs',
  'php',
  'lua',
  'r',
  'sql',
  'sh',
  'bash',
  'zsh',
  'fish',
  'ps1',
  'gradle',
  'cmake',
  'ini',
  'cfg',
  'conf',
  'env',
  'log',
  'tex',
  'bib',
  'svg',
  'vue',
  'svelte',
  'graphql',
  'proto',
  'dockerfile',
  'makefile',
  'gitignore',
];

const imageExtensions = ['png', 'jpg', 'jpeg', 'gif', 'webp'];
const pdfExtensions = ['pdf'];
const audioExtensions = ['mp3', 'wav'];

String _ext(String name) {
  final lower = name.toLowerCase();
  final dot = lower.lastIndexOf('.');
  // "Makefile", "Dockerfile": the whole name.
  return dot == -1 ? lower : lower.substring(dot + 1);
}

AttachmentKind kindOf(String name, Uint8List bytes, {String? mime}) {
  final ext = _ext(name);
  if (_imageTypes.containsKey(ext) || (mime != null && _imageTypes.containsValue(mime))) return AttachmentKind.image;
  if (ext == 'pdf' || mime == 'application/pdf') return AttachmentKind.pdf;
  if (_audioTypes.containsKey(ext) || (mime?.startsWith('audio/') ?? false)) return AttachmentKind.audio;
  if (textExtensions.contains(ext) || (mime?.startsWith('text/') ?? false)) return AttachmentKind.text;
  // Unknown extension: text if it decodes as UTF-8 without NULs.
  if (bytes.length <= AttachmentKind.text.maxBytes && !bytes.contains(0)) {
    try {
      utf8.decode(bytes);
      return AttachmentKind.text;
    } on FormatException {
      // binary
    }
  }
  return AttachmentKind.other;
}

String mimeOf(String name, AttachmentKind kind, [String? given]) {
  final ext = _ext(name);
  return switch (kind) {
    AttachmentKind.image => _imageTypes[ext] ?? given ?? 'image/png',
    AttachmentKind.pdf => 'application/pdf',
    AttachmentKind.audio => _audioTypes[ext] ?? given ?? 'audio/mpeg',
    AttachmentKind.text => 'text/plain',
    AttachmentKind.other => given ?? 'application/octet-stream',
  };
}

/// "512 KB", "4.2 MB".
String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).round()} KB';
  return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// The first of [candidates] that accepts every attachment (for "Switch to …").
ModelSpec? modelForAll(Iterable<AttachmentKind> kinds, Iterable<ModelSpec> candidates) {
  final needed = kinds.toSet();
  for (final m in candidates) {
    if (needed.every(m.accepts)) return m;
  }
  return null;
}

extension ModelAccepts on ModelSpec {
  bool accepts(AttachmentKind kind) => switch (kind) {
    AttachmentKind.text => true,
    AttachmentKind.other => false,
    AttachmentKind.image => imageInput || inputs.contains('image'),
    _ => inputs.contains(kind.modality),
  };
}
