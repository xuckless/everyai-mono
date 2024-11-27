import 'package:flutter/material.dart';
import '../models/chat_models.dart'; // Importing the chat models metadata
import '../widgets/default_app_bar.dart';
import '../widgets/menu_drawer.dart';
import '../models/api_service.dart';
import '../widgets/chat_body.dart';
import '../widgets/chat_pop_up_menu.dart'; // Import the ChatPopUpMenu

class HomeScreen extends StatefulWidget {
  final String title;

  const HomeScreen({super.key, required this.title});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, String>> availableVersions = [];
  final TextEditingController _messageController = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  String suffix = "";
  String subtitle = 'GPT-4o-mini';
  final FocusNode _focusNode = FocusNode();
  bool _isMenuVisible = false; // State variable to control menu visibility

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
    final initialModel = chatModels.firstWhere((model) => model["name"] == "ChatGPT");
    suffix = initialModel["versions"][0]["name"]!;
    subtitle = initialModel["versions"][0]["suffix"]!;
    availableVersions = initialModel["versions"];
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
          backgroundColor: const Color(0xFF181C26),
          appBar: DefaultAppBar(
            subtitle: subtitle,
            actions: [],
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
                availableVersions = selectedModel["versions"];
                _messages.clear();
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
        // Use AnimatedSwitcher for smooth transitions
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
        // Sort through available model and go to the 'selectedModel':
        final selectedModel = chatModels.firstWhere((model) =>
            model['versions'].any((version) => version['name'] == suffix));

        // Call the selected model's function
        final function = selectedModel['function'];

        // Check if function is valid
        if (function is Function) {
          // Same old Post Request, (see api_service)
          final response = await function(_messages.last['text'], suffix);
          _receiveMessage(response['message']);
        } else {
          throw Exception("Function not found for the selected ChatBot");
        }
      } catch (e) {
        _receiveMessage("Error: Could not fetch response."); // Show error message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e")),
        );
      }
    }
  }

  void _receiveMessage(String text) {
    setState(() {
      _messages.add({
        'text': text,
        'isSentByUser': false,
      });
    });
  }
}
