import 'package:flutter/material.dart';
import '../models/chat_models.dart'; // Importing the chat models metadata
import '../widgets/app-bar-widgets/default_app_bar.dart';
import '../widgets/my-library-widgets/menu_drawer.dart';
import '../widgets/chat-screen-widgets/chat_body.dart';
import 'dart:typed_data';
import '../widgets/app-bar-widgets/chat_pop_up_menu.dart'; // Import the ChatPopUpMenu

/// The main screen of the application where users can interact with chat functionalities.
///
/// The `ChatScreen` widget serves as the primary user interface for interacting with AI models.
/// Users can send messages, view responses (text and images), switch between different models,
/// and access additional options via a popup menu and navigation drawer.
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

/// State class that manages the logic and user interactions for [ChatScreen].
class _ChatScreenState extends State<ChatScreen> {
  /// List of available chat model versions for the currently selected model.
  List<Map<String, String>> availableVersions = [];

  /// Controller for the message input field.
  final TextEditingController _messageController = TextEditingController();

  /// List of chat messages displayed in the chat interface.
  ///
  /// Each message is represented as a map that can contain:
  /// - `text`: The message text.
  /// - `image`: Byte data representing an image.
  /// - `isSentByUser`: Boolean flag indicating if the message was sent by the user.
  final List<Map<String, dynamic>> _messages = [];

  /// Focus node for managing focus state of the message input field.
  final FocusNode _focusNode = FocusNode();

  /// State variable to control the visibility of the popup menu.
  bool _isMenuVisible = false;

  /// The currently selected AI model.
  String selectedModel = "ChatGPT"; // Default model

  /// The suffix that identifies the current model version.
  String selectedVersion = "GPT-4o-mini"; // Default version

  /// Text displayed in the popup menu indicating the selected model version.
  String selectedVersionDisplay = "GPT 4o mini";

  /// Path to the image asset representing the selected model.
  String selectedModelImage = "assets/models/chatgpt.webp"; // Default image

  @override
  void initState() {
    super.initState();
    // Initialize the available versions for the default selected model.
    _updateAvailableVersions(selectedModel);
  }

  /// Updates the list of available model versions for a selected model.
  ///
  /// - [modelName]: The name of the model to fetch available versions.
  void _updateAvailableVersions(String modelName) {
    final modelDetails = chatModels.firstWhere((model) => model["name"] == modelName);

    // Filter versions based on added status (if model is available)
    availableVersions = (modelDetails['versions'] as List<Map<String, String>>)
        .where((version) => chatModelAddedStatus[modelDetails['name']]!)
        .toList();

    // Set the selected version and display
    selectedVersion = availableVersions.isNotEmpty ? availableVersions[0]["name"]! : "";
    selectedVersionDisplay = availableVersions.isNotEmpty ? availableVersions[0]["suffix"]! : "";
    selectedModelImage = modelDetails['picture']; // Update model image
  }

  /// Updates the selected AI model and refreshes the list of available versions.
  ///
  /// This method also clears the current chat messages when switching models.
  ///
  /// - [modelName]: The name of the new model to switch to.
  void _updateModel(String modelName) {
    setState(() {
      selectedModel = modelName;
      _updateAvailableVersions(modelName);
      _messages.clear(); // Clear messages when model changes
    });
  }

  /// Updates the selected model version when the user selects a version from the menu.
  ///
  /// - [versionName]: The name of the version to switch to.
  void _updateVersion(String versionName) {
    setState(() {
      // Find the selected version and update suffix and display
      final versionDetails = availableVersions.firstWhere(
            (version) => version["name"] == versionName,
      );

      selectedVersion = versionName;
      selectedVersionDisplay = versionDetails["suffix"]!;

      print("Model remains: $selectedModel");
      print("Version updated to: $selectedVersion");
    });
  }

  /// Sends a message typed by the user to the selected AI model.
  ///
  /// This function adds the user's message to the chat, triggers the API request,
  /// and handles the response by adding the AI's reply or image to the chat.
  void _sendMessage() async {
    if (_messageController.text.trim().isNotEmpty) {
      setState(() {
        // Add user message to the chat list
        _messages.add({
          'text': _messageController.text.trim(),
          'isSentByUser': true,
        });
        _messageController.clear();
        _focusNode.requestFocus(); // Keep focus on input field
      });

      try {
        // Find the current model's API function
        final modelDetails = chatModels.firstWhere((model) =>
        model['name'] == selectedModel &&
            model['versions'].any((version) => version['name'] == selectedVersion));

        final function = modelDetails['function'];

        if (function is Function) {
          // Call the API and await the response
          final response = await function(_messages.last['text'], selectedVersion);

          // If the response is an image (Uint8List), handle it accordingly
          if (response is Uint8List) {
            _receiveMessage(response);
          } else {
            _receiveMessage("Failed to generate image.");
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

  /// Handles incoming messages from the AI, either text or image.
  ///
  /// - [response]: The AI's response, which can be a text message or an image.
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
          ),
          body: ChatBody(
            messages: _messages,
            messageController: _messageController,
            focusNode: _focusNode,
            onSendMessage: _sendMessage,
          ),
        ),
      ],
    );
  }
}