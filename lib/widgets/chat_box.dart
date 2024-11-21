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
      style: TextStyle(
          color: isSentByUser ? Colors.black : Colors.white,
        fontFamily: 'NotoSans',
        fontSize: 15
      ),
    );
  }

  List<TextSpan> _parseMessageForRichText(String message, BuildContext context) {
    final List<TextSpan> spans = [];
    // Combined regex patterns for Markdown
    final RegExp combinedRegex = RegExp(
      r'(###\s*(.+?)\n)|'         // Headings
      r'(\*\*(.+?)\*\*)|'         // Bold
      r'(\*(.+?)\*)|'             // Italic
      r'```(.*?)```|'             // Code block (multi-line)
      r'(`(.+?)`)|'               // Inline code
      r'(-\s(.+))',               // List items
      dotAll: true,
    );

    int currentIndex = 0;

    // Iterate through all matches
    combinedRegex.allMatches(message).forEach((match) {
      // Add any plain text before the current match
      if (match.start > currentIndex) {
        spans.add(TextSpan(
          text: message.substring(currentIndex, match.start).replaceAll('\n', '\n'),
        ));
      }

      // Determine which formatting applies
      if (match.group(1) != null) {
        // Heading match
        spans.add(TextSpan(
          text: match.group(2),
          style: const TextStyle(
            fontSize: 21.0,
            fontWeight: FontWeight.bold,
            color: Colors.blue,
          ),
        ));
      } else if (match.group(3) != null) {
        // Bold match
        spans.add(TextSpan(
          text: match.group(4),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ));
      } else if (match.group(5) != null) {
        // Italic match
        spans.add(TextSpan(
          text: match.group(6),
          style: const TextStyle(fontStyle: FontStyle.italic),
        ));
      } else if (match.group(7) != null) {
        // Code block match
        final codeContent = match.group(7)?.replaceAll('\n', '\n');
        spans.add(TextSpan(
          text: '\n$codeContent\n', // Add line breaks around code block
          style: const TextStyle(
            fontFamily: 'SourceCodePro',
            fontSize: 15,
            backgroundColor: Colors.grey,
            color: Colors.black,
          ),
        ));
      } else if (match.group(8) != null) {
        // Inline code match
        spans.add(TextSpan(
          text: match.group(9),
          style: const TextStyle(
            fontFamily: 'SourceCodePro',
            fontSize: 15,
            backgroundColor: Colors.grey,
            color: Colors.black,
          ),
        ));
      } else if (match.group(10) != null) {
        // List item match
        spans.add(TextSpan(
          text: "- ${match.group(11)}\n",
          style: const TextStyle(fontWeight: FontWeight.normal),
        ));
      }

      // Update current index
      currentIndex = match.end;
    });

    // Add any remaining plain text after the last match
    if (currentIndex < message.length) {
      spans.add(TextSpan(
        text: message.substring(currentIndex).replaceAll('\n', '\n'),
      ));
    }

    return spans;
  }
}