import 'package:flutter/material.dart';
import '../models/chat_models.dart'; // Importing the chat models metadata
import '../widgets/app-bar-widgets/default_app_bar.dart';
import '../widgets/my-library-widgets/menu_drawer.dart';
// import '../models/api_service.dart';
import '../widgets/chat-screen-widgets/chat_body.dart';
import '../widgets/app-bar-widgets/chat_pop_up_menu.dart'; // Import the ChatPopUpMenu

/// The main screen of the application where users can interact with chat functionalities.
///
/// The `ChatScreen` widget provides a user interface for displaying chat messages,
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
  /// List of available chat model versions for the selected model.
  List<Map<String, String>> availableVersions = [];

  /// Controller for the message input field.
  final TextEditingController _messageController = TextEditingController();

  /// List of chat messages, each containing text and a flag indicating the sender.
  final List<Map<String, dynamic>> _messages = [];

  /// Focus node for managing focus on the message input field.
  final FocusNode _focusNode = FocusNode();

  /// State variable to control the visibility of the popup menu.
  bool _isMenuVisible = false;

  /// Name of the currently selected chat model.
  String selectedModel = "ChatGPT"; // Default model

  /// Suffix used to identify the selected version of the current model.
  String selectedVersion = "GPT-4o-mini"; // Default version

  // This is what the pop up menu displays on the user screen
  String selectedVersionDisplay = "GPT 4o mini";

  /// Image asset path for the currently selected model.
  String selectedModelImage = "assets/models/chatgpt.webp"; // Default image

  @override
  void initState() {
    super.initState();
    // Initialize the default chat model versions
    _updateAvailableVersions(selectedModel);
  }

  /// Updates the list of available versions for the given model.
  ///
  /// - [modelName]: The name of the model whose versions should be updated.
  void _updateAvailableVersions(String modelName) {
    final modelDetails = chatModels.firstWhere((model) => model["name"] == modelName);
    availableVersions = (modelDetails['versions'] as List<Map<String, String>>)
        .where((version) => chatModelAddedStatus[modelDetails['name']]!)
        .toList();
    selectedVersion = availableVersions.isNotEmpty ? availableVersions[0]["name"]! : "";
    selectedVersionDisplay = availableVersions.isNotEmpty ? availableVersions[0]["suffix"]! : "";
    selectedModelImage = modelDetails['picture'];
  }

  /// Updates the selected chat model and resets the available versions.
  ///
  /// - [modelName]: The name of the model to select.
  /// Updates the selected chat model and resets the available versions.
  ///
  /// - [modelName]: The name of the model to select.
  void _updateModel(String modelName) {
    setState(() {
      selectedModel = modelName; // Ensure image displays model name
      _updateAvailableVersions(modelName); // Refresh available versions
      _messages.clear(); // Clear chat messages when switching models
    });
  }

  /// Updates the selected version of the current model.
  ///
  /// - [versionName]: The name of the version to select.
  /// Updates the selected version of the current model.
  ///
  /// - [versionName]: The name of the version to select.
  void _updateVersion(String versionName) {
    setState(() {

      // Find the corresponding suffix for the selected version
      final versionDetails = availableVersions.firstWhere(
            (version) => version["name"] == versionName,
      );



      selectedVersion = versionName; // Update the selected version
      selectedVersionDisplay = versionDetails["suffix"]!;

      final suffix = versionDetails["suffix"]; // Get the suffix
      print("Model remains: $selectedModel");
      print("Version updated to: $selectedVersion");
      print("Suffix updated to: $suffix");
    });
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
        // Find the selected model based on the selected model and version
        final modelDetails = chatModels.firstWhere((model) =>
        model['name'] == selectedModel &&
            model['versions'].any((version) => version['name'] == selectedVersion));

        // Retrieve the function associated with the selected model
        final function = modelDetails['function'];
        if (function is Function) {
          // Make the post request using the API service
          final response = await function(_messages.last['text'], selectedVersion);
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
              height: 35,
              width: 35,
              fit: BoxFit.cover, // Adjust fit as needed
            ),
            popUpText: selectedVersionDisplay,
            onPopUpTap: () {
              setState(() {
                _isMenuVisible = !_isMenuVisible; // Toggle popup menu visibility
              });
            },
            actions: [], // Add any additional actions here
          ),
          drawer: DrawerComponent(
            onModelSelected: (modelName) {
              setState(() {
                _updateModel(modelName);
                _isMenuVisible = false; // Hide menu if visible
              });
            },
          ),
          body: ChatBody(
            messages: _messages,
            messageController: _messageController,
            focusNode: _focusNode,
            onSendMessage: _sendMessage,
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
                top: 75 + MediaQuery.of(context).padding.top + 8, // AppBar height + status bar + spacing
                right: 5, // Position menu to the right
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    width: screenWidth * 0.4, // Set constrained width for the menu
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
                        _updateVersion(versionName); // Update the version and image
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
}