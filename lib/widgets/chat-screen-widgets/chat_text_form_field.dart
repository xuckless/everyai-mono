// chat_text_form_field.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';

/// A stateful widget that provides a customizable text input field for chat messages.
///
/// The `ChatTextFormField` widget includes features such as:
/// - Dynamic adjustment of the number of input lines based on user input.
/// - Handling of "Enter" key presses to either send the message or insert a newline.
/// - A send button to manually send the message.
/// - Platform-specific UI adjustments (e.g., extra margin for iOS).
class ChatTextFormField extends StatefulWidget {
  /// Controller for managing the text input of the message field.
  final TextEditingController messageController;

  /// Focus node to manage the focus state of the message field.
  final FocusNode focusNode;

  /// Callback function invoked when the user sends a message.
  final VoidCallback onSendMessage;

  /// Creates an instance of [ChatTextFormField].
  ///
  /// - [messageController]: Controller for the message input field.
  /// - [focusNode]: Focus node for managing focus.
  /// - [onSendMessage]: Callback triggered upon sending a message.
  const ChatTextFormField({
    required this.messageController,
    required this.focusNode,
    required this.onSendMessage,
    super.key,
  });

  @override
  State<ChatTextFormField> createState() => _ChatTextFormFieldState();
}

class _ChatTextFormFieldState extends State<ChatTextFormField> {
  /// Maximum number of lines allowed in the text input field.
  int _maxLines = 1;

  /// Focus node to listen for keyboard events.
  late FocusNode _keyboardListenerFocusNode;

  @override
  void initState() {
    super.initState();
    _keyboardListenerFocusNode = FocusNode();

    // Adds a listener to adjust the number of input lines dynamically.
    widget.messageController.addListener(_adjustMaxLines);
  }

  @override
  void dispose() {
    // Disposes the focus node to free resources.
    _keyboardListenerFocusNode.dispose();

    // Removes the listener to prevent memory leaks.
    widget.messageController.removeListener(_adjustMaxLines);
    super.dispose();
  }

  /// Adjusts the maximum number of input lines based on the number of newline characters.
  ///
  /// Limits the number of lines between 1 and 6.
  void _adjustMaxLines() {
    setState(() {
      final lines = '\n'.allMatches(widget.messageController.text).length + 1;
      _maxLines = lines.clamp(1, 6); // Limit to 6 lines
    });
  }

  /// Resets the maximum number of input lines to 1.
  void _resetMaxLines() {
    setState(() {
      _maxLines = 1;
    });
  }

  /// Handles key events within the text input field.
  ///
  /// - If "Enter" is pressed with the "Shift" key, inserts a newline.
  /// - If "Enter" is pressed without the "Shift" key, sends the message.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter) {
      // Checks if either Shift key is pressed.
      if (HardwareKeyboard.instance.logicalKeysPressed
          .contains(LogicalKeyboardKey.shiftLeft) ||
          HardwareKeyboard.instance.logicalKeysPressed
              .contains(LogicalKeyboardKey.shiftRight)) {
        final text = widget.messageController.text;
        final selection = widget.messageController.selection;
        final newText = text.replaceRange(
          selection.start,
          selection.end,
          '\n',
        );
        widget.messageController.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: selection.start + 1),
        );
        return KeyEventResult.handled;
      } else {
        // Sends the message if "Enter" is pressed without "Shift".
        widget.onSendMessage();
        widget.messageController.clear();
        _resetMaxLines();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // Determines if the current platform is iOS for adaptive UI adjustments.
    final bool isIOS = Platform.isIOS;

    return Focus(
      focusNode: _keyboardListenerFocusNode,
      onKeyEvent: (FocusNode node, KeyEvent event) =>
          _handleKeyEvent(node, event), // Handles key events
      child: Container(
        margin: EdgeInsets.fromLTRB(
          8.0,
          8.0,
          8.0,
          isIOS ? 18.3 : 8.0, // Adds extra margin for iOS at the bottom
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF2A3041), // Background color of the input field
          borderRadius: BorderRadius.circular(9999.0), // Fully rounded field
        ),
        child: Row(
          children: [
            // Expanded text input field
            Expanded(
              child: TextFormField(
                controller: widget.messageController,
                focusNode: widget.focusNode,
                maxLines: _maxLines, // Dynamic number of lines
                minLines: 1,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(color: Colors.white), // White text color
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(
                    vertical: 12.0,
                    horizontal: 16.0,
                  ), // Padding inside the input field
                  border: InputBorder.none, // No visible border
                  hintText: "Type a message", // Placeholder text
                  hintStyle: TextStyle(color: Colors.white54), // Placeholder style
                ),
              ),
            ),
            // Custom Send Button
            Container(
              margin: const EdgeInsets.only(right: 8.0), // Spacing from the text field
              child: InkWell(
                onTap: widget.onSendMessage, // Sends the message when tapped
                borderRadius:
                BorderRadius.circular(1500.0), // Circular border for the button
                child: Container(
                  padding: const EdgeInsets.all(6.0), // Size of the button
                  decoration: BoxDecoration(
                    color: const Color(0xFF181C26), // Background color of the button
                    borderRadius:
                    BorderRadius.circular(1500.0), // Fully rounded button
                  ),
                  child: const Icon(
                    Icons.arrow_upward, // Icon representing the send action
                    color: Colors.white, // Icon color
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}