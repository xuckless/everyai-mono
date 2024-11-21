import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ChatTextFormField extends StatefulWidget {
  final TextEditingController messageController;
  final FocusNode focusNode; // Renamed for consistency
  final VoidCallback onSendMessage;

  const ChatTextFormField({
    required this.messageController,
    required this.focusNode, // Updated parameter name
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
      onKeyEvent: (FocusNode node, KeyEvent event) => _handleKeyEvent(node, event),
      child: TextFormField(
        controller: widget.messageController,
        focusNode: widget.focusNode,
        maxLines: _maxLines,
        minLines: 1,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        decoration: InputDecoration(
          fillColor: Theme.of(context).colorScheme.primaryContainer,
          labelText: "Chat",
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8.0),
          ),
        ),
      ),
    );
  }
}