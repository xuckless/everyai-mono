import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/preferences.dart';
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
  PanelTarget? build() {
    final pending = ref.read(pendingArtifactOpenProvider).remove(conversationId);
    return pending == null ? null : ArtifactTarget(pending);
  }

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

  String get _key => 'artifacts.quiz.$callId';

  /// Restored from [Preferences], so answers survive a restart.
  @override
  Map<int, int> build() {
    final saved = ref.read(preferencesProvider)[_key];
    if (saved == null) return const {};
    try {
      return Map.unmodifiable({
        for (final e in (jsonDecode(saved) as Map<String, Object?>).entries)
          if (int.tryParse(e.key) case final q? when e.value is int) q: e.value as int,
      });
    } on Object {
      return const {};
    }
  }

  void answer(int question, int option) {
    if (state.containsKey(question)) return; // first answer counts
    state = Map.unmodifiable({...state, question: option});
    _save();
  }

  void reset() {
    state = const {};
    _save();
  }

  void _save() =>
      ref.read(preferencesProvider)[_key] = state.isEmpty ? null : jsonEncode(state.map((k, v) => MapEntry('$k', v)));
}

/// Where the user is in a flashcard deck: the current card and which cards
/// they marked known or still learning.
@immutable
final class FlashcardProgress {
  const FlashcardProgress({this.index = 0, this.known = const {}, this.learning = const {}});

  final int index;
  final Set<int> known;
  final Set<int> learning;

  Map<String, Object?> toJson() => {'index': index, 'known': known.toList(), 'learning': learning.toList()};

  static FlashcardProgress fromJson(Object? json) => switch (json) {
    {'index': final int index, 'known': final List<Object?> known, 'learning': final List<Object?> learning} =>
      FlashcardProgress(
        index: index,
        known: known.whereType<int>().toSet(),
        learning: learning.whereType<int>().toSet(),
      ),
    _ => const FlashcardProgress(),
  };
}

/// A flashcard deck's progress, keyed by tool call id and kept in
/// [Preferences] (shared by the inline card and the panel).
final flashcardProgressProvider = NotifierProvider.family<FlashcardDeck, FlashcardProgress, String>(FlashcardDeck.new);

final class FlashcardDeck extends Notifier<FlashcardProgress> {
  FlashcardDeck(this.callId);
  final String callId;

  String get _key => 'artifacts.cards.$callId';

  @override
  FlashcardProgress build() {
    final saved = ref.read(preferencesProvider)[_key];
    if (saved == null) return const FlashcardProgress();
    try {
      return FlashcardProgress.fromJson(jsonDecode(saved));
    } on FormatException {
      return const FlashcardProgress();
    }
  }

  /// Moves [delta] cards, wrapping around a deck of [count].
  void go(int delta, int count) {
    if (count == 0) return;
    _set(FlashcardProgress(index: (state.index + delta) % count, known: state.known, learning: state.learning));
  }

  /// Marks the current card, then moves to the next one.
  void mark({required bool known, required int count}) {
    final i = state.index;
    _set(
      FlashcardProgress(
        index: state.index,
        known: known ? {...state.known, i} : ({...state.known}..remove(i)),
        learning: known ? ({...state.learning}..remove(i)) : {...state.learning, i},
      ),
    );
    go(1, count);
  }

  void reset() => _set(const FlashcardProgress());

  void _set(FlashcardProgress p) {
    state = p;
    ref.read(preferencesProvider)[_key] = jsonEncode(p.toJson());
  }
}

/// Panel width chosen by dragging the divider, in logical pixels; null uses
/// the default share of the window. Kept in [Preferences].
final artifactPanelWidthProvider = NotifierProvider<ArtifactPanelWidth, double?>(ArtifactPanelWidth.new);

final class ArtifactPanelWidth extends Notifier<double?> {
  static const _key = 'artifacts.panel_width';

  @override
  double? build() => double.tryParse(ref.read(preferencesProvider)[_key] ?? '');

  /// Updates the width while dragging; [persist] stores it (on release).
  void set(double? width, {bool persist = true}) {
    state = width;
    if (persist) ref.read(preferencesProvider)[_key] = width?.round().toString();
  }
}

/// An artifact open for hand-editing in the panel: the version it started
/// from and the text so far.
@immutable
final class ArtifactEdit {
  const ArtifactEdit({required this.artifactId, required this.base, required this.text});

  final String artifactId;
  final Visual base;
  final String text;

  bool get changed => text != base.str('content');
}

/// The panel's hand-edit of one conversation, null when not editing.
final artifactEditProvider = NotifierProvider.autoDispose.family<ArtifactEditor, ArtifactEdit?, String>(
  ArtifactEditor.new,
);

final class ArtifactEditor extends Notifier<ArtifactEdit?> {
  ArtifactEditor(this.conversationId);
  final String conversationId;

  @override
  ArtifactEdit? build() => null;

  void start(String artifactId, Visual base) =>
      state = ArtifactEdit(artifactId: artifactId, base: base, text: base.str('content'));

  void update(String text) {
    if (state case final edit?) state = ArtifactEdit(artifactId: edit.artifactId, base: edit.base, text: text);
  }

  void cancel() => state = null;

  /// Saves the text as the artifact's next version (`update_artifact`,
  /// `edited_by: user`), which the model sees on its next turn. False while
  /// an answer is streaming; true when saved or there was nothing to save.
  Future<bool> save() async {
    final edit = state;
    if (edit == null) return true;
    if (!edit.changed) {
      state = null;
      return true;
    }
    final saved = await ref.read(chatSessionProvider(conversationId).notifier).saveUserArtifact('update_artifact', {
      'id': edit.artifactId,
      'content': edit.text,
    });
    if (saved) state = null;
    return saved;
  }
}

/// Artifacts to open when their chat next shows (conversation id → artifact
/// id): set by the Artifacts page before it navigates, taken by the chat's
/// panel when it is created.
final pendingArtifactOpenProvider = Provider<Map<String, String>>((ref) => {});

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
