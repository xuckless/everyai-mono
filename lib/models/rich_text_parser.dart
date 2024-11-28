// rich_text_parser.dart

import 'package:flutter/material.dart';
import '../widgets/code_block_widget.dart';

/// A utility class that parses markdown-like text into a list of [InlineSpan]s.
///
/// The `RichTextParser` class provides a static method `parseMessage` which takes a
/// message string containing markdown-like syntax and converts it into a list of
/// [InlineSpan]s. This allows for rich text rendering within Flutter widgets like [RichText].
class RichTextParser {
  /// Parses the given [message] and converts it into a list of [InlineSpan]s.
  ///
  /// The parser handles the following markdown-like syntaxes:
  /// - Headings (### Heading)
  /// - Bold (**bold text**)
  /// - Italic (*italic text*)
  /// - Code blocks (```code```)
  /// - Inline code (`code`)
  /// - List items (- item)
  ///
  /// If the parser encounters any errors, it defaults to rendering the entire message as plain text.
  ///
  /// [message]: The input string containing markdown-like syntax.
  /// [context]: The build context used for theme-related styling.
  ///
  /// Returns a list of [InlineSpan]s representing the parsed message.
  static List<InlineSpan> parseMessage(String message, BuildContext context) {
    final List<InlineSpan> spans = [];

    // Combined regular expression to match different markdown syntaxes.
    final RegExp combinedRegex = RegExp(
      r'(###\s*(.+?)\n)|'         // Headings (### Heading)
      r'(\*\*(.+?)\*\*)|'         // Bold (**bold text**)
      r'(\*(.+?)\*)|'             // Italic (*italic text*)
      r'```([\s\S]*?)```|'        // Code block (```code```)
      r'`([^`]+)`|'               // Inline code (`code`)
      r'(-\s(.+))',               // List items (- item)
      dotAll: true,                // Enables '.' to match newline characters
    );

    int currentIndex = 0; // Tracks the current position in the message string

    try {
      // Iterate over all matches found by the combined regex
      combinedRegex.allMatches(message).forEach((match) {
        // Add any text before the current match as plain text
        if (match.start > currentIndex) {
          spans.add(TextSpan(
            text: message.substring(currentIndex, match.start),
          ));
        }

        // Handle Heading
        if (match.group(1) != null) {
          spans.add(TextSpan(
            text: match.group(2), // Extracted heading text
            style: TextStyle(
              fontSize: 21.0,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ));
        }
        // Handle Bold
        else if (match.group(3) != null) {
          spans.add(TextSpan(
            text: match.group(4), // Extracted bold text
            style: const TextStyle(fontWeight: FontWeight.bold),
          ));
        }
        // Handle Italic
        else if (match.group(5) != null) {
          spans.add(TextSpan(
            text: match.group(6), // Extracted italic text
            style: const TextStyle(fontStyle: FontStyle.italic),
          ));
        }
        // Handle Code Block
        else if (match.group(7) != null) {
          spans.add(WidgetSpan(
            child: CodeBlockWidget(codeContent: match.group(7) ?? ""),
          ));
        }
        // Handle Inline Code
        else if (match.group(8) != null) {
          spans.add(TextSpan(
            text: match.group(8), // Extracted inline code
            style: const TextStyle(
              fontFamily: 'SourceCodePro',
              fontSize: 15,
              backgroundColor: Colors.grey,
              color: Colors.black,
            ),
          ));
        }
        // Handle List Item
        else if (match.group(9) != null) {
          spans.add(TextSpan(
            text: "- ${match.group(10)}\n", // Extracted list item
            style: const TextStyle(fontWeight: FontWeight.normal),
          ));
        }

        currentIndex = match.end; // Update the current index to the end of the match
      });

      // Add any remaining text after the last match as plain text
      if (currentIndex < message.length) {
        spans.add(TextSpan(
          text: message.substring(currentIndex),
        ));
      }
    } catch (e, stackTrace) {
      // Log the error and fallback to rendering the entire message as plain text
      debugPrint("Error in RichTextParser.parseMessage: $e");
      debugPrint(stackTrace.toString());
      spans.add(TextSpan(text: message));
    }

    return spans;
  }
}