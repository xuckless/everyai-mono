import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../questions/ui/question_card.dart';
import '../chat_providers.dart';
import '../domain/ask_user.dart';
import '../domain/message.dart';

/// The model's `ask_user` call in the chat: Code's question card, answerable
/// while the turn waits on it. A reply typed in the composer settles it too.
class AskUserCard extends ConsumerWidget {
  const AskUserCard({super.key, required this.part, required this.conversationId});

  final ToolCallPart part;
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = chatSessionProvider(conversationId);
    final callId = part.callId;
    final waiting = ref.watch(provider.select((s) => s.pendingTools.any((t) => t.id == callId)));
    final outcome = AskUserOutcome.fromJson(part.resultJson);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: QuestionCard(
        key: ValueKey('ask_user:$callId'),
        questions: askUserQuestions(part),
        answers: outcome?.answers,
        reply: outcome?.reply,
        enabled: waiting,
        closedLabel: 'No longer waiting for an answer',
        onSubmit: (answers) {
          if (callId != null) ref.read(provider.notifier).answerQuestions(callId, AskUserOutcome.answered(answers));
        },
      ),
    );
  }
}
