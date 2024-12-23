import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import '../../models/chat_models.dart';

/// A stateful widget that provides a customizable text input field for chat messages.
///
/// The `ChatTextFormField` includes:
/// - Dynamic adjustment of input lines based on user input.
/// - Detection of the '@' character to trigger model suggestions.
/// - Handling keyboard events to manage message sending.
/// - Overlay display of model suggestions filtered by category.
///
/// This widget integrates with an external list of chat models and dynamically
/// shows relevant models in a popup when the user types '@'.
class ChatTextFormField extends StatefulWidget {
  /// Controller for managing the text input in the message field.
  final TextEditingController messageController;

  /// Focus node to manage focus on the message input field.
  final FocusNode focusNode;

  /// Callback function triggered when the send button is pressed.
  final VoidCallback onSendMessage;

  /// **New**: A callback that notifies the parent widget when a temporary
  /// model is selected via '@'.
  ///
  /// Parameters:
  /// - `modelName`: The model name chosen by the user
  /// - `suffix`: The suffix corresponding to that model version
  final void Function(String modelName, String suffix)? onTempModelSelected;

  /// Constructs a [ChatTextFormField] widget.
  ///
  /// Requires a [messageController], [focusNode], and [onSendMessage] callback.
  /// The [onTempModelSelected] is optional; if not provided, no override occurs.
  const ChatTextFormField({
    required this.messageController,
    required this.focusNode,
    required this.onSendMessage,
    this.onTempModelSelected, // new
    super.key,
  });

  @override
  State<ChatTextFormField> createState() => _ChatTextFormFieldState();
}

/// State class for managing the behavior of the chat input field.
class _ChatTextFormFieldState extends State<ChatTextFormField> {
  /// Maximum number of lines allowed in the input field.
  int _maxLines = 1;

  /// Focus node to listen for keyboard events and handle '@' detection.
  late FocusNode _keyboardListenerFocusNode;

  /// Overlay entry to display model suggestions dynamically.
  OverlayEntry? _overlayEntry;

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

  /// Listens for text changes in the input field.
  ///
  /// Triggers a model suggestion popup when the user types '@' at the end of the input.
  void _onTextChanged() {
    final text = widget.messageController.text;
    if (text.endsWith('@')) {
      _showModelSuggestions();
    } else {
      _removeOverlay();
    }
  }

  /// Displays a popup with model suggestions filtered by 'Text-To-Image' category.
  ///
  /// The popup appears dynamically near the input field when '@' is detected.
  void _showModelSuggestions() {
    final overlay = Overlay.of(context);
    final renderBox = context.findRenderObject() as RenderBox;
    final size = renderBox.size;
    final offset = renderBox.localToGlobal(Offset.zero);

    final filteredModels = chatModels
        .where((model) => model['category'] == 'Text-To-Image')
        .toList();

    if (filteredModels.isEmpty) return;

    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: offset.dx + 16,
        bottom: size.height + 24,
        width: size.width * 0.8,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          color: const Color(0xFF2A3041),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: filteredModels.map((model) {
              return ListTile(
                title: Text(
                  model['name'],
                  style: const TextStyle(color: Colors.white),
                ),
                leading: CircleAvatar(
                  backgroundImage: AssetImage(model['picture']),
                  radius: 16,
                ),
                onTap: () {
                  final String modelName = model['name'];
                  final String suffix = model['versions'][0]['suffix'];

                  // Append styled model name with trailing space and red background
                  final text = widget.messageController.text;
                  final newText = text.replaceAll('@', '');
                  final richText = TextSpan(
                    text: '$modelName ',
                    style: const TextStyle(
                      backgroundColor: Colors.red,
                      color: Colors.white,
                    ),
                  );
                  widget.messageController.value = TextEditingValue(
                    text: '$newText ',
                    selection: TextSelection.collapsed(
                        offset: ('$newText ').length),
                  );

                  widget.messageController.text += modelName + ' ';

                  // Trigger parent callback if provided
                  if (widget.onTempModelSelected != null) {
                    widget.onTempModelSelected!(modelName, suffix);
                  }

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




  /// Removes the currently displayed overlay if it exists.
  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    // Adjust bottom margin for iOS devices to prevent overlapping the keyboard
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
            // Send button positioned to the right of the text input field
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
