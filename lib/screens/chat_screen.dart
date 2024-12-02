// chat_screen.dart

import 'package:flutter/material.dart';
import '../models/chat_models.dart'; // Importing the chat models metadata
import '../widgets/default_app_bar.dart';
import '../widgets/menu_drawer.dart';
import '../models/api_service.dart';
import '../widgets/chat_body.dart';
import '../widgets/chat_pop_up_menu.dart'; // Import the ChatPopUpMenu

/// The main screen of the application where users can interact with chat functionalities.
///
/// The `HomeScreen` widget provides a user interface for displaying chat messages,
/// sending new messages, and selecting different chat models. It includes features such
/// as a custom app bar, navigation drawer, chat body, and a popup menu for selecting
/// chat versions.
class ChatScreen extends StatefulWidget {
  /// The title displayed in the app bar.
  final String title;

  /// Creates an instance of [ChatScreen].
  ///
  /// - [title]: The title displayed in the app bar.
  const ChatScreen({super.key, required this.title});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  /// List of available chat model versions.
  List<Map<String, String>> availableVersions = [];

  /// Controller for the message input field.
  final TextEditingController _messageController = TextEditingController();

  /// List of chat messages, each containing text and a flag indicating the sender.
  final List<Map<String, dynamic>> _messages = [];

  /// Suffix used to identify the selected chat model version.
  String suffix = "";

  /// Subtitle displayed in the app bar, indicating the current chat model.
  String subtitle = 'GPT-4o-mini';

  /// Focus node for managing focus on the message input field.
  final FocusNode _focusNode = FocusNode();

  /// State variable to control the visibility of the popup menu.
  bool _isMenuVisible = false;

  /// Updates the selected chat model version based on user selection.
  ///
  /// - [versionName]: The name of the selected version.
  void _updateVersion(String versionName) {
    setState(() {
      suffix = versionName;
      final selectedVersion =
      availableVersions.firstWhere((version) => version["name"] == versionName);
      subtitle = selectedVersion["suffix"]!;
    });

    print("Subtitle updated to: $subtitle");
    print("Suffix updated to: $suffix");
  }

  @override
  void initState() {
    super.initState();
    // Initialize the default chat model version
    final initialModel = chatModels.firstWhere((model) => model["name"] == "ChatGPT");
    suffix = initialModel["versions"][0]["name"]!;
    subtitle = initialModel["versions"][0]["suffix"]!;
    // availableVersions = initialModel["versions"];
    availableVersions = (initialModel['versions'] as List<Map<String, String>>)
            .where((version) => chatModelAddedStatus[initialModel['name']]!)
            .toList();
  }


  @override
  Widget build(BuildContext context) {
    // Calculate the desired width as a percentage of screen width
    final double screenWidth = MediaQuery.of(context).size.width;
    final double desiredWidth = screenWidth * 0.5; // 50% of screen width
    final double maxWidth = 300.0; // Maximum width
    final double minWidth = 150.0; // Minimum width

    // Ensure the popupWidth is within the min and max bounds
    final double popupWidth = desiredWidth.clamp(minWidth, maxWidth);

    return Stack(
      children: [
        Scaffold(
          backgroundColor: const Color(0xFF181C26), // Sets the background color
          appBar: DefaultAppBar(
            subtitle: subtitle,
            actions: [], // Add any additional actions here
            onSubtitleTap: () {
              setState(() {
                _isMenuVisible = !_isMenuVisible; // Toggle menu visibility
              });
            },
          ),
          drawer: DrawerComponent(
            onModelSelected: (modelName) {
              setState(() {
                final selectedModel =
                chatModels.firstWhere((model) => model["name"] == modelName);
                suffix = selectedModel["versions"][0]["name"]!;
                subtitle = selectedModel["versions"][0]["suffix"]!;
                // availableVersions = selectedModel["versions"];
                setState(() {
                  availableVersions = (selectedModel['versions'] as List<Map<String, String>>)
                      .where((version) => chatModelAddedStatus[selectedModel['name']]!)
                      .toList();
                });
                print("Filtered versions: $availableVersions");
                _messages.clear(); // Clear messages when model changes
                _isMenuVisible = false; // Hide menu if visible
              });
            },
          ),
          body: ChatBody(
            messages: _messages,
            messageController: _messageController,
            focusNode: _focusNode,
            onSendMessage: _sendMessage, // Use your existing _sendMessage method
          ),
        ),
        // Use AnimatedSwitcher for smooth transitions of the popup menu
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
              // Overlay to detect taps outside the menu
              Positioned.fill(
                key: const ValueKey('overlay'),
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _isMenuVisible = false; // Hide menu when tapping outside
                    });
                  },
                  behavior: HitTestBehavior.translucent,
                  child: Container(
                    color: Colors.black.withOpacity(0.3), // Semi-transparent overlay
                  ),
                ),
              ),
              // Popup Menu Positioned at the desired location
              Positioned(
                key: const ValueKey('popupMenu'),
                top: 75 + MediaQuery.of(context).padding.top + 8, // AppBar height + status bar + spacing
                left: (screenWidth - popupWidth) / 2, // Center horizontally
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    width: popupWidth, // Set the constrained width
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A3041), // Background color of the menu
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
                          _isMenuVisible = false; // Hide menu after selection
                        });
                      },
                    ),
                  ),
                ),
              ),
            ],
          )
              : const SizedBox.shrink(), // Empty widget when menu is not visible
        ),
      ],
    );
  }

  /// Sends a message entered by the user.
  ///
  /// This method adds the user's message to the chat, sends it to the backend API,
  /// and handles the response by adding the AI's reply to the chat.
  void _sendMessage() async {
    if (_messageController.text.trim().isNotEmpty) {
      setState(() {
        // Add the user's message to the chat
        _messages.add({
          'text': _messageController.text.trim(),
          'isSentByUser': true,
        });
        _messageController.clear(); // Clear the input field
        _focusNode.requestFocus(); // Keep the keyboard focused
      });

      try {
        // Find the selected model based on the suffix
        final selectedModel = chatModels.firstWhere((model) =>
            model['versions'].any((version) => version['name'] == suffix));

        // Retrieve the function associated with the selected model
        final function = selectedModel['function'];

        // Check if the function is valid
        if (function is Function) {
          // Make the post request using the API service
          final response = await function(_messages.last['text'], suffix);
          _receiveMessage(response['message']);
        } else {
          throw Exception("Function not found for the selected ChatBot");
        }
      } catch (e) {
        // Handle errors by displaying an error message
        _receiveMessage("Error: Could not fetch response."); // Show error message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e")),
        );
      }
    }
  }

  /// Receives and displays a message from the AI.
  ///
  /// - [text]: The message text to display.
  void _receiveMessage(String text) {
    setState(() {
      _messages.add({
        'text': text,
        'isSentByUser': false,
      });
    });
  }
}