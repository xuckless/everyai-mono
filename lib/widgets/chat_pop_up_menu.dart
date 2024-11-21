import 'package:flutter/material.dart';

class ChatPopUpMenu extends StatelessWidget {
  final List<Map<String, String>> availableVersions;
  final Function(String) onVersionSelected;

  const ChatPopUpMenu({
    super.key,
    required this.availableVersions,
    required this.onVersionSelected,
  });

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