import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';

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
  OverlayEntry? _overlayEntry;

  final List<String> _fruitSuggestions = ['🍎 Appluhje', '🍌 Banana', '🍇 Grape'];

  @override
  void initState() {
    super.initState();
    _keyboardListenerFocusNode = FocusNode();
    widget.messageController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _keyboardListenerFocusNode.dispose();
    widget.messageController.removeListener(_onTextChanged);
    _overlayEntry?.remove();
    super.dispose();
  }

  void _onTextChanged() {
    final text = widget.messageController.text;
    if (text.endsWith('@')) {
      _showFruitSuggestions();
    } else {
      _removeOverlay();
    }
  }

  void _showFruitSuggestions() {
    final overlay = Overlay.of(context);
    final renderBox = context.findRenderObject() as RenderBox;
    final size = renderBox.size;
    final offset = renderBox.localToGlobal(Offset.zero);

    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: offset.dx + 16,
        bottom: size.height + 24,  // Adjusts position near input field
        width: size.width * 0.8,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          color: const Color(0xFF2A3041),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _fruitSuggestions.map((fruit) {
              return ListTile(
                title: Text(
                  fruit,
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  widget.messageController.text += fruit.split(' ')[1];  // Append selected fruit
                  _removeOverlay();
                },
              );
            }).toList(),
          ),
        ),
      ),
    );

    overlay.insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    final bool isIOS = Platform.isIOS;

    return Focus(
      focusNode: _keyboardListenerFocusNode,
      child: Container(
        margin: EdgeInsets.fromLTRB(
          8.0,
          8.0,
          8.0,
          isIOS ? 18.3 : 8.0,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF2A3041),
          borderRadius: BorderRadius.circular(9999.0),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: widget.messageController,
                focusNode: widget.focusNode,
                maxLines: _maxLines,
                minLines: 1,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(
                    vertical: 12.0,
                    horizontal: 16.0,
                  ),
                  border: InputBorder.none,
                  hintText: "Type a message",
                  hintStyle: TextStyle(color: Colors.white54),
                ),
              ),
            ),
            Container(
              margin: const EdgeInsets.only(right: 8.0),
              child: InkWell(
                onTap: widget.onSendMessage,
                borderRadius: BorderRadius.circular(1500.0),
                child: Container(
                  padding: const EdgeInsets.all(6.0),
                  decoration: BoxDecoration(
                    color: const Color(0xFF181C26),
                    borderRadius: BorderRadius.circular(1500.0),
                  ),
                  child: const Icon(
                    Icons.arrow_upward,
                    color: Colors.white,
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
