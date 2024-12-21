import 'package:flutter/material.dart';
import 'chat_box.dart';
import 'chat_text_form_field.dart';

/// A widget that represents the main body of the chat interface.
///
/// The `ChatBody` widget is responsible for displaying a list of chat messages,
/// handling text input, and rendering user-generated and AI-generated content, including images.
/// This widget manages the layout of chat bubbles and input fields, ensuring smooth interaction.
class ChatBody extends StatelessWidget {
  /// A list of chat messages represented as maps.
  ///
  /// Each map contains keys such as:
  /// - `'text'`: The textual content of the message.
  /// - `'image'`: The binary data for an image message (optional).
  /// - `'isSentByUser'`: A boolean indicating if the message was sent by the user.
  final List<Map<String, dynamic>> messages;

  /// Controller for managing text input in the message field.
  ///
  /// This controller allows the app to clear, modify, or read the content
  /// of the text input field.
  final TextEditingController messageController;

  /// A focus node to manage focus on the text input field.
  ///
  /// This focus node can be used to shift focus to or away from the input field,
  /// controlling keyboard visibility and focus behavior.
  final FocusNode focusNode;

  /// A callback function triggered when the user sends a message.
  ///
  /// This function handles the event of sending a message, allowing
  /// communication between the input field and the chat message list.
  final VoidCallback onSendMessage;

  /// Constructs the `ChatBody` widget.
  ///
  /// - [messages]: A list of chat messages to display.
  /// - [messageController]: Controller for text input.
  /// - [focusNode]: Focus node for the input field.
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
        // Expanded widget to ensure the message list takes available space
        Expanded(
          child: SingleChildScrollView(
            reverse: true,  // Scrolls to the bottom when new messages arrive
            child: Container(
              color: Colors.transparent,
              child: Column(
                children: messages.map((message) {
                  if (message.containsKey('image')) {
                    // Renders image messages
                    return Align(
                      alignment: Alignment.centerLeft,  // Aligns images to the left
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: 8.0, horizontal: 10.0),  // Adds vertical padding
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.15),
                                blurRadius: 10,
                                spreadRadius: 1,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.memory(
                              message['image'],
                              width: MediaQuery.of(context).size.width * 0.75,
                              height: 250,
                              fit: BoxFit.cover,  // Ensures images scale without distortion
                            ),
                          ),
                        ),
                      ),
                    );
                  } else {
                    // Renders text-based chat messages
                    return ChatBox(
                      message: message['text'] ?? '',
                      isSentByUser: message['isSentByUser'],
                    );
                  }
                }).toList(),
              ),
            ),
          ),
        ),
        // Row containing the text input field and send button
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: ChatTextFormField(
                  messageController: messageController,
                  focusNode: focusNode,
                  onSendMessage: onSendMessage,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}