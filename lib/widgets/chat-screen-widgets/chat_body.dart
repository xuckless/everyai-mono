import 'package:flutter/material.dart';
import 'chat_box.dart';
import 'chat_text_form_field.dart';

/// A widget that represents the main body of the chat interface.
///
/// The `ChatBody` widget handles the display of chat messages, both text and images,
/// in a scrollable list. It also provides a text input field for the user to send
/// messages. This widget leverages custom widgets like [ChatBox] for text messages
/// and [ChatTextFormField] for the input area.
class ChatBody extends StatelessWidget {
  /// A list of messages to display in the chat. Each message is a `Map` that can contain:
  /// - `text`: The message text to display.
  /// - `image`: The byte data of an image (if the message contains an image).
  /// - `isSentByUser`: A boolean flag indicating if the message was sent by the user.
  final List<Map<String, dynamic>> messages;

  /// A controller to handle the input text for the message field.
  final TextEditingController messageController;

  /// A [FocusNode] to manage the focus state of the input field.
  final FocusNode focusNode;

  /// A callback function triggered when the user sends a message.
  final VoidCallback onSendMessage;

  /// Creates an instance of [ChatBody].
  ///
  /// - [messages]: The list of chat messages to display.
  /// - [messageController]: Controller for handling message input.
  /// - [focusNode]: Focus node to manage input field focus.
  /// - [onSendMessage]: Callback function to handle sending messages.
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
        // Expanded widget allows the message list to take up remaining space
        Expanded(
          child: SingleChildScrollView(
            reverse: true,  // Ensures new messages are visible at the bottom
            child: Container(
              color: Colors.transparent,  // Background remains transparent
              child: Column(
                // Maps each message to either an image or text widget
                children: messages.map((message) {
                  if (message.containsKey('image')) {
                    // If the message contains an image, render it with styling
                    return Align(
                      alignment: Alignment.centerLeft,  // Align images to the left
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 8.0,
                          horizontal: 10.0,
                        ),  // Add vertical padding and slight horizontal spacing
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),  // Rounded corners
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.15),  // Shadow effect
                                blurRadius: 10,
                                spreadRadius: 1,
                                offset: Offset(0, 4),  // Shadow below the image
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),  // Clip image to rounded corners
                            child: Image.memory(
                              message['image'],  // Display image from byte data
                              width: MediaQuery.of(context).size.width * 0.75,  // 75% of screen width
                              height: 250,  // Fixed height for images
                              fit: BoxFit.cover,  // Scale and crop the image to fit
                            ),
                          ),
                        ),
                      ),
                    );
                  } else {
                    // Render text messages using the custom ChatBox widget
                    return ChatBox(
                      message: message['text'] ?? '',  // Display text or empty string
                      isSentByUser: message['isSentByUser'],  // Determines message alignment (left/right)
                    );
                  }
                }).toList(),  // Convert mapped messages to a list of widgets
              ),
            ),
          ),
        ),
        // Row for message input at the bottom of the chat screen
        Row(
          children: [
            // Text input field for composing messages
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8.0),  // Padding around the input field
                child: ChatTextFormField(
                  messageController: messageController,  // Attach controller to input field
                  focusNode: focusNode,  // Manage input focus state
                  onSendMessage: onSendMessage,  // Triggered when user sends a message
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}