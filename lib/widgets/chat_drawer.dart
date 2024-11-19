import 'package:flutter/material.dart';
import 'package:second_times_the_charm/widgets/custom_button.dart';
import '../models/chat_models.dart';
import '../models/login_handler.dart';

class ChatDrawer extends StatelessWidget {
  final Function(String) onModelSelected; // Callback for switching chat models

  const ChatDrawer({Key? key, required this.onModelSelected}) : super(key: key);



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
                  "Chat Switcher",
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.white,
                  )
                ),

                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CustomButton(
                          text: "Market",
                          onPressed: () => null,
                      ),

                      CustomButton(
                        text: "Logout",
                        onPressed: () => loginHandler.handleLogout(context),
                      ),
                    ],
                  ),

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
          }).toList(),
        ],
      ),
    );
  }
}