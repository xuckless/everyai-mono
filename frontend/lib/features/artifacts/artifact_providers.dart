import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_providers.dart';
import 'domain/artifact.dart';

/// What the side panel shows: an artifact (at a version) or a single visual.
@immutable
sealed class PanelTarget {
  const PanelTarget();
}

final class ArtifactTarget extends PanelTarget {
  const ArtifactTarget(this.artifactId, {this.version});
  final String artifactId;

  /// Null follows the latest version (it moves as the model revises).
  final int? version;
}

final class VisualTarget extends PanelTarget {
  const VisualTarget(this.visual);
  final Visual visual;
}

/// The side panel of one conversation. Null when closed.
final artifactPanelProvider = NotifierProvider.autoDispose.family<ArtifactPanelController, PanelTarget?, String>(
  ArtifactPanelController.new,
);

final class ArtifactPanelController extends Notifier<PanelTarget?> {
  ArtifactPanelController(this.conversationId);
  final String conversationId;

  @override
  PanelTarget? build() => null;

  void openArtifact(String id, {int? version}) => state = ArtifactTarget(id, version: version);

  void openVisual(Visual visual) => state = VisualTarget(visual);

  void close() => state = null;
}

/// Artifacts in a conversation, rebuilt when its messages change.
final conversationArtifactsProvider = Provider.autoDispose.family<List<Artifact>, String>(
  (ref, conversationId) => artifactsIn(ref.watch(chatSessionProvider(conversationId).select((s) => s.messages))),
);

/// Answers chosen in a quiz (question index → option index), shared by the
/// inline view and the panel. Keyed by tool call id.
final quizAnswersProvider = NotifierProvider.family<QuizAnswers, Map<int, int>, String>(QuizAnswers.new);

final class QuizAnswers extends Notifier<Map<int, int>> {
  QuizAnswers(this.callId);
  final String callId;

  @override
  Map<int, int> build() => const {};

  void answer(int question, int option) {
    if (state.containsKey(question)) return; // first answer counts
    state = Map.unmodifiable({...state, question: option});
  }

  void reset() => state = const {};
}

/// Whether a web page artifact runs its scripts (the panel's
/// static/interactive toggle). Keyed by artifact id, so it holds across
/// versions; on by default.
final webInteractiveProvider = NotifierProvider.family<WebInteractive, bool, String>(WebInteractive.new);

final class WebInteractive extends Notifier<bool> {
  WebInteractive(this.artifactId);
  final String artifactId;

  @override
  bool build() => true;

  void toggle() => state = !state;
}

/// A drawing's unsaved scene (the JSON the editor last reported), keyed by
/// the version being edited ([Visual.callId]); null when nothing changed.
final drawingDraftProvider = NotifierProvider.autoDispose.family<DrawingDraft, String?, String>(DrawingDraft.new);

final class DrawingDraft extends Notifier<String?> {
  DrawingDraft(this.versionKey);
  final String versionKey;

  @override
  String? build() => null;

  void set(String scene) => state = scene;

  void clear() => state = null;
}
