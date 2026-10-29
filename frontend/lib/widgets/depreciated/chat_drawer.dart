import 'package:flutter/material.dart';
import 'package:every_ai/models/utils/navigation.dart';
import 'package:every_ai/screens/marketplace.dart';
import 'package:every_ai/widgets/global-resource/custom_button.dart';
import '../../models/chat_models.dart';
import '../../models/utils/login_handler.dart';

class ChatDrawer extends StatelessWidget {
  final Function(String) onModelSelected; // Callback for switching chat models

  const ChatDrawer({super.key, required this.onModelSelected});

  @override
  Widget build(BuildContext context) {
    final loginHandler = LoginHandler();

    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.inversePrimary,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Every AI",
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8), // Add spacing between title and buttons
                Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(2.0),
                            child: CustomButton(
                              text: "Market",
                              onPressed: () => navigateToPage(context, Marketplace(title: 'Marketplace')),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(2.0),
                            child: CustomButton(
                              text: "Logout",
                              onPressed: () => loginHandler.handleLogout(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(2.0),
                            child: CustomButton(
                              text: "Profile",
                              onPressed: () {},
                            ),
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(2.0),
                            child: CustomButton(
                              text: "Dashboard",
                              onPressed: () {},
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          ...chatModels.map((chat) {
            return ListTile(
              title: Text(chat["name"]!), // Display the name of the chat model
              onTap: () {
                onModelSelected(chat["name"]!); // Trigger the callback
              },
            );
          }),
        ],
      ),
    );
  }
}