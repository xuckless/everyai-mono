import 'package:flutter/material.dart';

class ChatBox extends StatelessWidget {
  final String message;
  final bool isSentByUser;

  const ChatBox({required this.message, required this.isSentByUser});

  Widget build(BuildContext context) {
    return Align(
      alignment: isSentByUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        padding: EdgeInsets.all(10),
        margin: EdgeInsets.symmetric(vertical: 5, horizontal: 10),
        decoration: BoxDecoration(
          color: isSentByUser ? Colors.grey : Theme.of(context).primaryColorDark,
          borderRadius: BorderRadius.circular(10),
        ),
        child: SelectableText(
          message,
          style: TextStyle(color: isSentByUser ? Colors.black : Colors.white),
        ),
      ),
    );
  }
}