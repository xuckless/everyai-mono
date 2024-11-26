import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ChatTextFormField extends StatefulWidget {
  final TextEditingController messageController;
  final FocusNode focusNode;
  final VoidCallback onSendMessage;

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
  int _maxLines = 1;
  late FocusNode _keyboardListenerFocusNode;

  @override
  void initState() {
    super.initState();
    _keyboardListenerFocusNode = FocusNode();

    widget.messageController.addListener(_adjustMaxLines);
  }

  @override
  void dispose() {
    _keyboardListenerFocusNode.dispose();
    widget.messageController.removeListener(_adjustMaxLines);
    super.dispose();
  }

  void _adjustMaxLines() {
    setState(() {
      final lines = '\n'.allMatches(widget.messageController.text).length + 1;
      _maxLines = lines.clamp(1, 6); // Limit to 6 lines
    });
  }

  void _resetMaxLines() {
    setState(() {
      _maxLines = 1;
    });
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter) {
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
    return Focus(
      focusNode: _keyboardListenerFocusNode,
      onKeyEvent: (FocusNode node, KeyEvent event) =>
          _handleKeyEvent(node, event),
      child: Container(
        margin: const EdgeInsets.all(8.0), // Adjust spacing around the field
        decoration: BoxDecoration(
          color: const Color(0xFF2A3041), // Background color
          borderRadius: BorderRadius.circular(9999.0), // Fully rounded field
        ),
        child: Row(
          children: [
            // Text input field
            Expanded(
              child: TextFormField(
                controller: widget.messageController,
                focusNode: widget.focusNode,
                maxLines: _maxLines,
                minLines: 1,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(color: Colors.white), // White text color
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(
                    vertical: 12.0,
                    horizontal: 16.0,
                  ), // Adjust padding inside the input
                  border: InputBorder.none, // No visible border
                  hintText: "Type a message...",
                  hintStyle: TextStyle(color: Colors.white54), // Placeholder style
                ),
              ),
            ),
            // Custom Send Button
            Container(
              margin: const EdgeInsets.only(right: 8.0), // Spacing from text field
              child: InkWell(
                onTap: widget.onSendMessage,
                borderRadius: BorderRadius.circular(1500.0), // Adjust this for button shape
                child: Container(
                  padding: const EdgeInsets.all(6.0), // Button size
                  decoration: BoxDecoration(
                    color: Color(0xFF181C26), // Button background color
                    borderRadius: BorderRadius.circular(1500.0), // Adjustable border radius
                  ),
                  child: const Icon(Icons.arrow_upward, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

}
