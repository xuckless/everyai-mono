import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For LogicalKeyboardKey

class ChatTextFormField extends StatefulWidget {
  final TextEditingController messageController;
  final FocusNode focusNode;
  final VoidCallback onSendMessage;

  const ChatTextFormField({
    required this.messageController,
    required this.focusNode,
    required this.onSendMessage,
    Key? key,
  }) : super(key: key);

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

  KeyEventResult _handleKeyEvent(RawKeyEvent event) {
    if (event is RawKeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter) {
      if (event.isShiftPressed) {
        // Add a newline if Shift is pressed
        final newValue = "${widget.messageController.text}\n";
        widget.messageController.value = TextEditingValue(
            text: newValue,
            selection: TextSelection.collapsed(offset: newValue.length));
        return KeyEventResult.handled;
      } else {
        // Send message on Enter
        widget.onSendMessage();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return RawKeyboardListener(
      focusNode: _keyboardListenerFocusNode,
      onKey: _handleKeyEvent,
      child: TextFormField(
        controller: widget.messageController,
        focusNode: widget.focusNode,
        maxLines: _maxLines,
        minLines: 1,
        keyboardType: TextInputType.multiline,
        decoration: InputDecoration(
          fillColor: Theme.of(context).primaryColorLight,
          labelText: "Chat",
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4.0),
          ),
        ),
      ),
    );
  }
}