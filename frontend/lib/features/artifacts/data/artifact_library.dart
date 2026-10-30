import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/chat_providers.dart';
import '../../chat/data/chat_repository.dart';
import '../domain/artifact.dart';

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
