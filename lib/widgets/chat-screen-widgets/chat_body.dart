import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:second_times_the_charm/widgets/chat-screen-widgets/image_render_widget.dart';
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
    return ChangeNotifierProvider(
      create: (_) => ChatBodyLogic(),
      child: Column(
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
                      return ImageRenderer(imageData: message['image']);
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
      ),
    );
  }
}

class ChatBodyLogic with ChangeNotifier {
  void render(){
    notifyListeners();
  }
}
