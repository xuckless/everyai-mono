import 'package:flutter/material.dart';
import 'chat_box.dart';
import 'chat_text_form_field.dart';

class ChatBody extends StatelessWidget {
  final List<Map<String, dynamic>> messages;
  final TextEditingController messageController;
  final FocusNode focusNode;
  final VoidCallback onSendMessage;

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
        // Chat message list
        Expanded(
          child: SingleChildScrollView(
            reverse: true,
            child: Container(
              color: Colors.transparent,
              child: Column(
                children: messages.map((message) {
                  return ChatBox(
                    message: message['text'],
                    isSentByUser: message['isSentByUser'],
                  );
                }).toList(),
              ),
            ),
          ),
        ),
        // Chat input field and send button
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
            Container(
              width: 70,
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.transparent,
                  width: 10,
                ),
              ),
              child: FloatingActionButton(
                onPressed: onSendMessage,
                child: Icon(Icons.arrow_upward),
              ),
            ),
          ],
        ),
      ],
    );
  }
}