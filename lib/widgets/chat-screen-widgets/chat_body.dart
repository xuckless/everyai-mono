import 'package:flutter/material.dart';
import 'chat_box.dart';
import 'chat_text_form_field.dart';

class ChatBody extends StatelessWidget {
  final List<Map<String, dynamic>> messages;
  final TextEditingController messageController;
  final FocusNode focusNode;
  final VoidCallback onSendMessage;

  /// New: callback for whenever a user selects a model via '@' in the text field
  final void Function(String modelName, String suffix)? onTempModelSelected;

  const ChatBody({
    required this.messages,
    required this.messageController,
    required this.focusNode,
    required this.onSendMessage,
    this.onTempModelSelected, // new
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            reverse: true,
            child: Container(
              color: Colors.transparent,
              child: Column(
                children: messages.map((message) {
                  if (message.containsKey('image')) {
                    // Renders image messages
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: 8.0, horizontal: 10.0),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.15),
                                blurRadius: 10,
                                spreadRadius: 1,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.memory(
                              message['image'],
                              width: MediaQuery.of(context).size.width * 0.75,
                              height: 250,
                              fit: BoxFit.cover,
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
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: ChatTextFormField(
                  messageController: messageController,
                  focusNode: focusNode,
                  onSendMessage: onSendMessage,
                  onTempModelSelected: onTempModelSelected, // forward it
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
