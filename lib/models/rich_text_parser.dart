import 'package:flutter/material.dart';
import '../widgets/code_block_widget.dart';

class RichTextParser {
  static List<InlineSpan> parseMessage(String message, BuildContext context) {
    final List<InlineSpan> spans = [];
    final RegExp combinedRegex = RegExp(
      r'(###\s*(.+?)\n)|'         // Headings
      r'(\*\*(.+?)\*\*)|'         // Bold
      r'(\*(.+?)\*)|'             // Italic
      r'```([\s\S]*?)```|'        // Code block (multi-line)
      r'`([^`]+)`|'               // Inline code (single backticks)
      r'(-\s(.+))',               // List items
      dotAll: true,
    );

    int currentIndex = 0;

    try {
      combinedRegex.allMatches(message).forEach((match) {
        // Add any unmatched text as plain text
        if (match.start > currentIndex) {
          spans.add(TextSpan(
            text: message.substring(currentIndex, match.start),
          ));
        }

        if (match.group(1) != null) {
          // Heading
          spans.add(TextSpan(
            text: match.group(2),
            style: const TextStyle(
              fontSize: 21.0,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ));
        } else if (match.group(3) != null) {
          // Bold
          spans.add(TextSpan(
            text: match.group(4),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ));
        } else if (match.group(5) != null) {
          // Italic
          spans.add(TextSpan(
            text: match.group(6),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ));
        } else if (match.group(7) != null) {
          // Code block
          spans.add(WidgetSpan(
            child: CodeBlockWidget(codeContent: match.group(7) ?? ""),
          ));
        } else if (match.group(8) != null) {
          // Inline code
          spans.add(TextSpan(
            text: match.group(8),
            style: const TextStyle(
              fontFamily: 'SourceCodePro',
              fontSize: 15,
              backgroundColor: Colors.grey,
              color: Colors.black,
            ),
          ));
        } else if (match.group(9) != null) {
          // List item
          spans.add(TextSpan(
            text: "- ${match.group(10)}\n",
            style: const TextStyle(fontWeight: FontWeight.normal),
          ));
        }

        currentIndex = match.end;
      });

      // Add remaining unmatched text
      if (currentIndex < message.length) {
        spans.add(TextSpan(
          text: message.substring(currentIndex),
        ));
      }
    } catch (e, stackTrace) {
      debugPrint("Error in RichTextParser.parseMessage: $e");
      debugPrint(stackTrace.toString());
      spans.add(TextSpan(text: message)); // Fallback to plain text
    }

    return spans;
  }
}