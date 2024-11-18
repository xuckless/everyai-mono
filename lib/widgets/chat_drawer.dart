import 'package:flutter/material.dart';
import '../models/chat_models.dart';

class ChatDrawer extends StatelessWidget {
  final Function(String) onModelSelected; // Callback for switching chat models

  const ChatDrawer({Key? key, required this.onModelSelected}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.inversePrimary,
            ),
            child: Text(
              "Chat Switcher",
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.white,
              ),
            ),
          ),
          ...chatModels.map((chat) {
            return ListTile(
              title: Text(chat["name"]!), // Display the name of the chat model
              onTap: () {
                onModelSelected(chat["name"]!); // Trigger the callback
              },
            );
          }).toList(),
        ],
      ),
    );
  }
}