// chat_box.dart

import 'package:flutter/material.dart';
import '../../models/utils/rich_text_parser.dart';

/// A widget that represents an individual chat message in the chat interface.
///
/// The `ChatBox` widget displays a single message, styling it differently based
/// on whether it was sent by the user or the AI. It utilizes the [RichTextParser]
/// to render rich text within the message.
class ChatBox extends StatelessWidget {
  /// The text content of the chat message.
  final String message;

  /// A boolean indicating whether the message was sent by the user.
  final bool isSentByUser;

  /// Creates an instance of [ChatBox].
  ///
  /// - [message]: The text content of the chat message.
  /// - [isSentByUser]: Determines the alignment and styling of the message.
  const ChatBox({
    super.key,
    required this.message,
    required this.isSentByUser,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      // Aligns the message to the right if sent by the user, else to the left
      alignment: isSentByUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.all(10), // Padding inside the message box
        margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 10), // Margin around the message box
        decoration: isSentByUser
            ? BoxDecoration(
          color: const Color(0xFF2A3041), // Background color for user messages
          borderRadius: BorderRadius.circular(10), // Rounded corners
        )
            : null, // No decoration for AI messages
        child: _buildRichText(context), // Builds the rich text content
      ),
    );
  }

  /// Builds the rich text content of the chat message using [RichTextParser].
  ///
  /// - [context]: The build context used for theming and styling.
  ///
  /// Returns a [SelectableText.rich] widget that displays the parsed message.
  Widget _buildRichText(BuildContext context) {
    return SelectableText.rich(
      TextSpan(
        children: RichTextParser.parseMessage(message, context), // Parses the message for rich text
      ),
      style: TextStyle(
        color: Colors.white, // Text color
        fontFamily: 'NotoSans', // Font family
        fontSize: 15, // Font size
      ),
    );
  }
}