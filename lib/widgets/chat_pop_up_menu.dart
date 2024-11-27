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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: availableVersions.map((version) {
        return ListTile(
          title: Text(
            version["suffix"]!,
            style: TextStyle(color: Colors.white), // Change text color here
          ),
          onTap: () {
            onVersionSelected(version["name"]!);
          },
        );
      }).toList(),
    );
  }
}