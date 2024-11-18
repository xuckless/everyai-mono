import 'package:flutter/material.dart';

import 'chat_box.dart';

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
    Key? key,
  }) : super(key: key);

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
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width,
            maxHeight: 150,
          ),
          child: Row(
            children: [
              // Chat box
              Container(
                width: MediaQuery.of(context).size.width - 70,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Colors.transparent,
                    width: 10.0,
                  ),
                ),
                child: TextFormField(
                  controller: messageController,
                  focusNode: focusNode,
                  onFieldSubmitted: (_) => onSendMessage(),
                  decoration: InputDecoration(
                    fillColor: Theme.of(context).primaryColorLight,
                    labelText: "Chat",
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4.0),
                    ),
                  ),
                ),
              ),
              // Send button
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
        ),
      ],
    );
  }
}
