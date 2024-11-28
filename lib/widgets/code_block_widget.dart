// code_block_widget.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A widget that displays a code snippet with a copy-to-clipboard feature.
///
/// The `CodeBlockWidget` presents a styled container containing the code content.
/// Users can easily copy the displayed code to their clipboard by tapping the copy icon.
class CodeBlockWidget extends StatelessWidget {
  /// The code content to be displayed within the widget.
  final String codeContent;

  /// Creates an instance of [CodeBlockWidget].
  ///
  /// - [codeContent]: The code snippet to display.
  const CodeBlockWidget({super.key, required this.codeContent});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8.0), // Adds vertical spacing around the widget
      padding: const EdgeInsets.all(10.0), // Adds padding inside the container
      decoration: BoxDecoration(
        color: Colors.grey[200], // Sets the background color of the container
        borderRadius: BorderRadius.circular(8.0), // Rounds the corners of the container
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, // Aligns children to the start (left)
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween, // Spaces out the children evenly
            children: [
              const Text(
                "Code Snippet",
                style: TextStyle(
                  fontWeight: FontWeight.bold, // Makes the text bold
                  fontSize: 16, // Sets the font size
                ),
              ),
              IconButton(
                onPressed: () {
                  // Copies the code content to the clipboard
                  Clipboard.setData(ClipboardData(text: codeContent));
                  // Shows a snackbar notification confirming the copy action
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Code copied to clipboard!")),
                  );
                },
                icon: const Icon(Icons.copy), // Icon representing the copy action
              ),
            ],
          ),
          const SizedBox(height: 8.0), // Adds vertical spacing between the row and the code content
          Text(
            codeContent, // Displays the actual code content
            style: const TextStyle(
              fontFamily: 'SourceCodePro', // Sets the font family to a monospaced font
              fontSize: 14, // Sets the font size
              color: Colors.black87, // Sets the text color
            ),
          ),
        ],
      ),
    );
  }
}