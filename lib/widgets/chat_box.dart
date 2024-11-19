import 'package:flutter/material.dart';

class ChatBox extends StatelessWidget {
  final String message;
  final bool isSentByUser;

  const ChatBox({required this.message, required this.isSentByUser});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isSentByUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.all(10),
        margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 10),
        decoration: BoxDecoration(
          color: isSentByUser ? Colors.grey : Theme.of(context).primaryColorDark,
          borderRadius: BorderRadius.circular(10),
        ),
        child: _buildRichText(context),
      ),
    );
  }

  Widget _buildRichText(BuildContext context) {
    // Parsing the message for rich text formatting
    final List<TextSpan> spans = _parseMessageForRichText(message, context);

    return SelectableText.rich(
      TextSpan(
        children: spans,
      ),
      style: TextStyle(color: isSentByUser ? Colors.black : Colors.white),
    );
  }

  List<TextSpan> _parseMessageForRichText(String message, BuildContext context) {
    final List<TextSpan> spans = [];
    final RegExp boldRegex = RegExp(r'\*\*(.*?)\*\*'); // For bold text **text**
    final RegExp italicRegex = RegExp(r'\*(.*?)\*'); // For italic text *text*

    String remainingText = message;

    // Process bold formatting first
    while (boldRegex.hasMatch(remainingText)) {
      final match = boldRegex.firstMatch(remainingText)!;
      if (match.start > 0) {
        spans.add(TextSpan(text: remainingText.substring(0, match.start)));
      }
      spans.add(TextSpan(
        text: match.group(1),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ));
      remainingText = remainingText.substring(match.end);
    }

    // Process italic formatting
    while (italicRegex.hasMatch(remainingText)) {
      final match = italicRegex.firstMatch(remainingText)!;
      if (match.start > 0) {
        spans.add(TextSpan(text: remainingText.substring(0, match.start)));
      }
      spans.add(TextSpan(
        text: match.group(1),
        style: const TextStyle(fontStyle: FontStyle.italic),
      ));
      remainingText = remainingText.substring(match.end);
    }

    // Add any remaining text without formatting
    if (remainingText.isNotEmpty) {
      spans.add(TextSpan(text: remainingText));
    }

    return spans;
  }
}