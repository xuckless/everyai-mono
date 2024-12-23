import 'package:flutter/material.dart';
import '../models/chat_models.dart';
import '../widgets/app-bar-widgets/default_app_bar.dart';
import '../widgets/my-library-widgets/menu_drawer.dart';
import '../widgets/chat-screen-widgets/chat_body.dart';
import 'dart:typed_data';
import '../widgets/app-bar-widgets/chat_pop_up_menu.dart';

class ChatScreen extends StatefulWidget {
  final String title;

  const ChatScreen({super.key, required this.title});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  List<Map<String, String>> availableVersions = [];
  final TextEditingController _messageController = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  final FocusNode _focusNode = FocusNode();

  bool _isMenuVisible = false;

  /// The globally selected model and version
  String selectedModel = "ChatGPT";
  String selectedVersion = "GPT-4o-mini";
  String selectedVersionDisplay = "GPT 4o mini";
  String selectedModelImage = "assets/models/chatgpt.webp";

  // -------------- NEW --------------
  /// If user picks a temporary model via '@' suggestions
  String? _tempModelName;
  String? _tempSuffix;
  // --------------------------------

  @override
  void initState() {
    super.initState();
    _updateAvailableVersions(selectedModel);
  }

  void _updateAvailableVersions(String modelName) {
    final modelDetails =
    chatModels.firstWhere((model) => model["name"] == modelName);
    availableVersions = (modelDetails['versions'] as List<Map<String, String>>)
        .where((version) => chatModelAddedStatus[modelDetails['name']]!)
        .toList();
    selectedVersion = availableVersions.isNotEmpty
        ? availableVersions[0]["name"]!
        : "";
    selectedVersionDisplay = availableVersions.isNotEmpty
        ? availableVersions[0]["suffix"]!
        : "";
    selectedModelImage = modelDetails['picture'];
  }

  void _updateModel(String modelName) {
    setState(() {
      selectedModel = modelName;
      _updateAvailableVersions(modelName);
      _messages.clear();
    });
  }

  void _updateVersion(String versionName) {
    setState(() {
      final versionDetails = availableVersions.firstWhere(
            (version) => version["name"] == versionName,
      );
      selectedVersion = versionName;
      selectedVersionDisplay = versionDetails["suffix"]!;
    });
  }

  /// -------------- NEW --------------
  /// Called when the user picks a model from the '@' suggestions.
  /// We'll store it so that the next _sendMessage call can use it.
  void _handleTempModelSelected(String modelName, String suffix) {
    _tempModelName = modelName;
    _tempSuffix = suffix;
  }
  /// --------------------------------

  void _sendMessage() async {
    if (_messageController.text.trim().isNotEmpty) {
      setState(() {
        _messages.add({
          'text': _messageController.text.trim(),
          'isSentByUser': true,
        });
        _messageController.clear();
        _focusNode.requestFocus();
      });

      try {
        // Decide whether to use the global or the temp model for this request
        final String modelToUse = _tempModelName ?? selectedModel;
        final String? nameToUse = _tempSuffix ?? selectedVersion;

        // Once used, reset the temp values so next message uses the global model
        _tempModelName = null;
        _tempSuffix = null;

        // Find the model details
        final modelDetails = chatModels.firstWhere((model) =>
        model['name'] == modelToUse &&
            model['versions'].any((version) => version['name'] == nameToUse)
        );

        final function = modelDetails['function'];
        if (function is Function) {
          final response = await function(
            _messages.last['text'],
            nameToUse,
          );

          // Handle JSON or image response
          if (response is Map<String, dynamic> && response.containsKey('message')) {
            _receiveMessage(response['message']);
          } else if (response is Uint8List) {
            _receiveMessage(response);
          } else {
            _receiveMessage("Unexpected response type.");
          }
        } else {
          throw Exception("Function not found for the selected ChatBot");
        }
      } catch (e) {
        _receiveMessage("Error: Could not fetch response.");
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e")),
        );
      }
    }
  }

  void _receiveMessage(dynamic response) {
    setState(() {
      if (response is Uint8List) {
        _messages.add({
          'image': response,
          'isSentByUser': false,
        });
      } else {
        _messages.add({
          'text': response.toString(),
          'isSentByUser': false,
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;

    return Stack(
      children: [
        Scaffold(
          backgroundColor: const Color(0xFF181C26),
          appBar: DefaultAppBar(
            image: Image.asset(
              selectedModelImage,
              height: 25,
              width: 25,
              fit: BoxFit.cover,
            ),
            popUpText: selectedVersionDisplay,
            onPopUpTap: () {
              setState(() {
                _isMenuVisible = !_isMenuVisible;
              });
            },
            actions: [],
          ),
          drawer: DrawerComponent(
            onModelSelected: (modelName) {
              setState(() {
                _updateModel(modelName);
                _isMenuVisible = false;
              });
            },
          ),
          body: ChatBody(
            messages: _messages,
            messageController: _messageController,
            focusNode: _focusNode,
            onSendMessage: _sendMessage,
            // Pass in our new callback
            onTempModelSelected: _handleTempModelSelected,
          ),
        ),
        // AnimatedSwitcher for the popup menu ...
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          transitionBuilder: (Widget child, Animation<double> animation) {
            return FadeTransition(
              opacity: animation,
              child: child,
            );
          },
          child: _isMenuVisible
              ? Stack(
            key: const ValueKey('popupStack'),
            children: [
              Positioned.fill(
                key: const ValueKey('overlay'),
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _isMenuVisible = false;
                    });
                  },
                  behavior: HitTestBehavior.translucent,
                  child: Container(
                    color: Colors.black.withOpacity(0.3),
                  ),
                ),
              ),
              Positioned(
                top: 75 + MediaQuery.of(context).padding.top + 8,
                right: 5,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    width: screenWidth * 0.4,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A3041),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: ChatPopUpMenu(
                      availableVersions: availableVersions,
                      onVersionSelected: (versionName) {
                        _updateVersion(versionName);
                        setState(() {
                          _isMenuVisible = false;
                        });
                      },
                    ),
                  ),
                ),
              ),
            ],
          )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
