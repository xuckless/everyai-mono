import 'package:flutter/material.dart';
import '../models/rich_text_parser.dart';

class ChatBox extends StatelessWidget {
  final String message;
  final bool isSentByUser;

  const ChatBox({super.key, required this.message, required this.isSentByUser});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isSentByUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.all(10),
        margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 10),
        decoration: isSentByUser ? BoxDecoration(
          color: const Color(0xFF2A3041),
          borderRadius: BorderRadius.circular(10)) : null,
        child: _buildRichText(context),
      ),
    );
  }

  Widget _buildRichText(BuildContext context) {
    return SelectableText.rich(
      TextSpan(
        children: RichTextParser.parseMessage(message, context),
      ),
      style: TextStyle(
        color: Colors.white,
        fontFamily: 'NotoSans',
        fontSize: 15,
      ),
    );
  }
}