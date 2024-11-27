import 'package:flutter/material.dart';
import 'package:second_times_the_charm/models/api_service.dart';
import 'package:second_times_the_charm/widgets/chat_body.dart';
import 'package:second_times_the_charm/widgets/default_app_bar.dart';
import 'package:second_times_the_charm/widgets/menu_drawer.dart';
import '../models/chat_models.dart'; // Importing the chat models metadata
import '../widgets/chat_pop_up_menu.dart';

// Main screen for the chat interface
class ChatScreen extends StatefulWidget {
  final String title; // Title for the screen

  const ChatScreen({super.key, required this.title});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  // List of available versions for the currently selected chat model
  List<Map<String, String>> availableVersions = [];

  // Controller for handling user input in the chat
  final TextEditingController _messageController = TextEditingController();

  // List of messages for the current chat session
  final List<Map<String, dynamic>> _messages = [];

  // Service to handle API calls for chat
  final ApiService _apiService = ApiService();

  // Current suffix (unique identifier) for the selected chat version
  String suffix = "";

  // Subtitle displayed under the AppBar title, representing the selected chat version
  String subtitle = 'GPT-4o-mini';

  // Focus node for managing keyboard focus on the chat input
  final FocusNode _focusNode = FocusNode();



  // Method to send a message and handle API response
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

      // try {
      //   // Send the message to the backend and fetch the response
      //   final response = suffix.isNotEmpty
      //       ? await _apiService.d_chat(_messages.last['text'], suffix)
      //       : await _apiService.chat(_messages.last['text']);
      //
      //   _receiveMessage(response['message']); // Display the response
      // }

      try{

        // Sort through available model and go to the 'selectedModel':
        final selectedModel = chatModels.firstWhere((model) =>
          model['versions'].any((version) => version['name'] == suffix)
        );

        // call the selected model's function
        final function = selectedModel['function'];

        // check if function is valid (True if the function actually exists)
        if (function is Function){
          //Same old Post Request, (see api_service)
          final response = await function(_messages.last['text'], suffix);
          _receiveMessage(response['message']);
        } else {
          throw Exception("Function not found, for selected ChatBot");
        }

      } catch (e) {
        _receiveMessage("Error: Could not fetch response."); // Show error message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e")),
        );
      }
    }
  }



  // Method to add a received message to the chat
  void _receiveMessage(String text) {
    setState(() {
      _messages.add({
        'text': text,
        'isSentByUser': false,
      });
    });
  }



  // Method to switch chat models and initialize versions for the new model
  void _switchChatModel(String modelName) {
    setState(() {
      final selectedModel = chatModels.firstWhere((model) => model["name"] == modelName);

      // Set suffix and subtitle based on the first version of the new model
      suffix = selectedModel["versions"][0]['name']!;
      subtitle = selectedModel["versions"][0]['suffix']!;

      // Update available versions for the new model
      availableVersions = selectedModel["versions"];

      // Clear messages for the new chat instance
      _messages.clear();
    });

    // Debugging logs to ensure proper updates
    print("Subtitle updated to: $subtitle");
    print("Suffix updated to: $suffix");

    // Close the drawer after selection
    Navigator.of(context).pop();
  }




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

    // Initialize the screen with the default ChatGPT model and its first version
    final initialModel = chatModels.firstWhere((model) => model["name"] == "ChatGPT");
    suffix = initialModel["versions"][0]["name"]!; // Set suffix to the first version's name
    subtitle = initialModel["versions"][0]["suffix"]!; // Set subtitle to the first version's suffix
    availableVersions = initialModel["versions"]; // Load available versions
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF181C26), // Set the background color of the screen
      appBar: DefaultAppBar(
        subtitle: subtitle, // Display the current version as a subtitle
        actions: [

          // Popup menu for switching between versions
          ChatPopUpMenu(
            availableVersions: availableVersions,
            onVersionSelected: _updateVersion, // Handle version selection
          ),
        ],
      ),


      //add the drawer to the screen
      drawer: DrawerComponent(
        onModelSelected: _switchChatModel,
      ),


      // Body of the screen, displaying the chat and input
      body: ChatBody(
        messages: _messages, // Pass the list of messages
        messageController: _messageController, // Pass the input controller
        focusNode: _focusNode, // Manage keyboard focus
        onSendMessage: _sendMessage, // Handle sending messages
      ),
      drawerScrimColor: Colors.transparent,
    );
  }
}