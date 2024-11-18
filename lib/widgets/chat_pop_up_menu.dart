import 'package:flutter/material.dart';
import '../models/chat_models.dart';

class ChatPopUpMenu extends StatelessWidget {
  final List<Map<String, String>> availableVersions;
  final Function(String) onVersionSelected;

  const ChatPopUpMenu({
    Key? key,
    required this.availableVersions,
    required this.onVersionSelected,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      onSelected: (value) {
        onVersionSelected(value); // Trigger the callback
      },
      itemBuilder: (BuildContext context) {
        return availableVersions.map((version) {
          return PopupMenuItem<String>(
            value: version["name"], // Pass the version's name as the value
            child: Text(version["suffix"]!), // Display the version's suffix
          );
        }).toList();
      },
    );
  }
}