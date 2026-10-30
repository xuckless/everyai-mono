import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/net/api_error.dart';
import '../../../core/providers.dart';
import '../../billing/billing_providers.dart';
import '../../chat/chat_providers.dart';
import '../artifact_providers.dart';
import '../domain/artifact.dart';
import '../export/svg_raster.dart';

/// What one Polish round (`POST /v1/figures/polish`) sent back.
@immutable
final class PolishResult {
  const PolishResult({
    required this.svg,
    required this.defects,
    required this.changed,
    required this.chargedMicros,
    this.keptOriginal,
  });

  factory PolishResult.fromJson(Map<String, Object?> json) => PolishResult(
    svg: json['svg'] as String? ?? '',
    defects: [for (final d in json['defects'] as List? ?? const []) ?d as String?],
    changed: json['changed'] as bool? ?? false,
    chargedMicros: (json['charged_micros'] as num?)?.toInt() ?? 0,
    keptOriginal: json['kept_original'] as String?,
  );

  /// The figure to keep: the revision, or the original when nothing changed.
  final String svg;

  /// What the reviewer saw wrong in the render.
  final List<String> defects;

  /// Whether [svg] differs from what was sent.
  final bool changed;
  final int chargedMicros;

  /// Why the revision was dropped (it failed the checks), when it was.
  final String? keptOriginal;
}

/// A figure Polish can't start (it couldn't be drawn, or the chat is busy).
final class PolishError implements Exception {
  const PolishError(this.message);
  final String message;
}

/// POSTs a JSON body and returns the decoded reply.
typedef PolishPost = Future<Map<String, Object?>> Function(Map<String, Object?> body);

/// The SVG source of a figure visual: inline figures and vector images keep
/// it in `svg`, artifacts in `content`.
String svgOf(Visual v) => v.args['svg'] as String? ?? v.str('content');

/// Renders [svg] the way the app shows it and asks the backend to look at
/// the picture and revise the figure once.
Future<PolishResult> polishFigure({
  required String svg,
  required SvgRasterizer rasterize,
  required PolishPost post,
  String? brief,
  String? session,
}) async {
  final raster = await rasterize(svg);
  if (raster == null) throw const PolishError('This figure could not be drawn, so it cannot be polished.');
  return PolishResult.fromJson(
    await post({
      'svg': svg,
      'png_base64': base64Encode(raster.png),
      if (brief != null && brief.isNotEmpty) 'brief': brief,
      'session': ?session,
    }),
  );
}

/// The tool calls that store a polished figure as a version: the next
/// version of an artifact made with create_artifact, otherwise a new SVG
/// artifact whose first version is the original (so the user can step back).
List<(String, Map<String, Object?>)> polishSaves(
  Visual v,
  Artifact? artifact,
  String polished, {
  required String newId,
}) {
  if (artifact != null && v.args['svg'] == null) {
    return [
      ('update_artifact', {'id': artifact.id, 'content': polished}),
    ];
  }
  return [
    ('create_artifact', {'id': newId, 'kind': 'svg', 'title': v.title, 'content': svgOf(v)}),
    ('update_artifact', {'id': newId, 'content': polished}),
  ];
}

/// Raster sent to the reviewer: about 768 px wide, enough to see defects
/// without spending many image tokens.
Future<RasterFigure?> _reviewRaster(String svg) => rasterizeSvg(svg, maxWidth: 384, scale: 2);

/// Whether a Polish round is running, per conversation.
final figurePolishProvider = NotifierProvider.autoDispose.family<FigurePolisher, bool, String>(FigurePolisher.new);

final class FigurePolisher extends Notifier<bool> {
  FigurePolisher(this.conversationId);
  final String conversationId;

  @override
  bool build() => false;

  /// Polishes [v] and saves the result as a new version, then shows it.
  /// Returns a short message for a toast.
  Future<String> polish(Visual v, Artifact? artifact) async {
    if (state) return 'Already polishing';
    final chat = chatSessionProvider(conversationId);
    if (ref.read(chat).phase.busy) return 'Wait for the answer to finish, then polish';
    state = true;
    try {
      final api = ref.read(apiClientProvider);
      final authenticated = !ref.read(appConfigProvider).devSkipAuth;
      final result = await polishFigure(
        svg: svgOf(v),
        rasterize: _reviewRaster,
        brief: v.title,
        session: conversationId,
        post: (body) =>
            api.postJson('v1/figures/polish', body, authenticated: authenticated, timeout: const Duration(minutes: 3)),
      );
      final cost = result.chargedMicros > 0 ? ' (${formatMicros(result.chargedMicros)})' : '';
      if (!result.changed) {
        return result.defects.isEmpty
            ? 'Nothing to fix$cost'
            : 'Found ${_issues(result.defects.length)} but the fix didn\'t pass the checks$cost';
      }
      final id = 'polished-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
      final saves = polishSaves(v, artifact, result.svg, newId: id);
      final session = ref.read(chat.notifier);
      for (final (tool, args) in saves) {
        if (!await session.saveUserArtifact(tool, args)) return 'Wait for the answer to finish, then polish';
      }
      ref.read(artifactPanelProvider(conversationId).notifier).openArtifact(saves.first.$2['id']! as String);
      final fixed = result.defects.isEmpty ? 'Polished' : 'Fixed ${_issues(result.defects.length)}';
      return '$fixed, saved as a new version$cost';
    } on PolishError catch (e) {
      return e.message;
    } on ApiError catch (e) {
      return e.message;
    } finally {
      if (ref.mounted) state = false;
    }
  }
}

String _issues(int n) => n == 1 ? '1 issue' : '$n issues';
