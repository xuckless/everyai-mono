import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/chat_providers.dart';
import '../../chat/data/chat_repository.dart';
import '../domain/artifact.dart';
import '../domain/figures.dart';
import '../domain/slide_spec.dart';

/// One artifact on the Artifacts page, with the chat it lives in.
@immutable
final class LibraryArtifact {
  const LibraryArtifact({required this.conversationId, required this.chatTitle, required this.artifact});

  final String conversationId;
  final String chatTitle;
  final Artifact artifact;

  /// Whether [query] (lowercase) appears in the title, the chat's title or
  /// the kind.
  bool matches(String query) =>
      query.isEmpty ||
      artifact.title.toLowerCase().contains(query) ||
      chatTitle.toLowerCase().contains(query) ||
      artifact.latest.kind.label.toLowerCase().contains(query);
}

/// Every chat's artifacts: chats most recently updated first, and inside a
/// chat the newest artifact first.
Future<List<LibraryArtifact>> loadArtifactLibrary(ChatRepository repo, List<String> conversationIds) async {
  final out = <LibraryArtifact>[];
  for (final id in conversationIds) {
    final conversation = await repo.conversation(id);
    if (conversation == null) continue;
    final artifacts = artifactsIn(await repo.messages(id));
    for (final a in artifacts.reversed) {
      out.add(LibraryArtifact(conversationId: id, chatTitle: conversation.title, artifact: a));
    }
  }
  return out;
}

/// The Artifacts page's list, rebuilt when messages change.
final artifactLibraryProvider = StreamProvider.autoDispose<List<LibraryArtifact>>((ref) {
  final repo = ref.watch(chatRepositoryProvider);
  return repo.watchArtifactConversations().asyncMap((ids) => loadArtifactLibrary(repo, ids));
});

/// A figure in the library (an SVG, chart or diagram with an id), and the documents and decks of its chat that
/// show it.
typedef LibraryFigure = ({LibraryArtifact item, List<String> usedIn});

/// The figures among [all], newest chats first as [all] is, each with where it is used.
List<LibraryFigure> figuresInLibrary(List<LibraryArtifact> all) {
  final byChat = <String, List<LibraryArtifact>>{};
  for (final a in all) {
    (byChat[a.conversationId] ??= []).add(a);
  }
  return [
    for (final a in all)
      if (const {VisualKind.svg, VisualKind.chart, VisualKind.diagram}.contains(a.artifact.latest.kind) &&
          a.artifact.latest.str('id').isNotEmpty)
        (
          item: a,
          usedIn: [
            for (final other in byChat[a.conversationId]!)
              if ((other.artifact.latest.kind == VisualKind.document &&
                      figureRefsIn(other.artifact.latest.str('content')).contains(a.artifact.id)) ||
                  (other.artifact.latest.kind == VisualKind.slides &&
                      pictureRefsOf(deckOf(other.artifact.latest)).contains(a.artifact.id)))
                other.artifact.title,
          ],
        ),
  ];
}
