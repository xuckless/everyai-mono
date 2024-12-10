// chat_body.dart

import 'package:flutter/material.dart';
import 'chat_box.dart';
import 'chat_text_form_field.dart';

/// A widget that represents the main body of the chat interface.
///
/// The `ChatBody` widget displays a list of chat messages and provides an input
/// field for sending new messages. It leverages custom widgets like [ChatBox] to
/// render individual messages and [ChatTextFormField] for the message input area.
class ChatBody extends StatelessWidget {
  /// A list of chat messages where each message is a map containing the text
  /// and a boolean indicating if it was sent by the user.
  final List<Map<String, dynamic>> messages;

  /// Controller for managing the text input of the message field.
  final TextEditingController messageController;

  /// Focus node to manage the focus state of the message field.
  final FocusNode focusNode;

  /// Callback function invoked when the user sends a message.
  final VoidCallback onSendMessage;

  /// Creates an instance of [ChatBody].
  ///
  /// - [messages]: The list of chat messages to display.
  /// - [messageController]: Controller for the message input field.
  /// - [focusNode]: Focus node for managing focus.
  /// - [onSendMessage]: Callback triggered upon sending a message.
  const ChatBody({
    required this.messages,
    required this.messageController,
    required this.focusNode,
    required this.onSendMessage,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Expanded widget to make the message list take up available space
        Expanded(
          child: SingleChildScrollView(
            reverse: true, // Scrolls to the bottom when new messages are added
            child: Container(
              color: Colors.transparent, // Transparent background
              child: Column(
                children: messages.map((message) {
                  return ChatBox(
                    message: message['text'], // The message text
                    isSentByUser: message['isSentByUser'], // Sender flag
                  );
                }).toList(),
              ),
            ),
          ),
        ),
        // Row containing the message input field and send button
        Row(
          children: [
            // Expanded to make the input field take up remaining space
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8.0), // Padding around the input field
                child: ChatTextFormField(
                  messageController: messageController, // Controller for the input
                  focusNode: focusNode, // Focus node for the input
                  onSendMessage: onSendMessage, // Callback for sending messages
                ),
              ),
            ),
            /*
            // Uncomment this section if you prefer a FloatingActionButton for sending messages
            Container(
              width: 70, // Width of the send button container
              decoration: BoxDecoration(
                 border: Border.all(
                  color: Colors.transparent,
                  width: 10,
                ),
              ),
              child: FloatingActionButton(
                onPressed: onSendMessage, // Sends the message when pressed
                child: Icon(Icons.arrow_upward), // Send icon
              ),
            ),
            */
          ],
        ),
      ],
    );
  }
}