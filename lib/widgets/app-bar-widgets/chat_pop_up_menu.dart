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
      children: [
        ...availableVersions.map((version) {
          return ListTile(
            title: Text(
              version["suffix"]!,
              style: const TextStyle(color: Colors.white),
            ),
            onTap: () {
              onVersionSelected(version["name"]!);
            },
          );
        }).toList(),
        Padding(
          padding: const EdgeInsets.all(12.0),  // Space around the button
          child: TextButton(
            style: TextButton.styleFrom(
              backgroundColor: Colors.red,
              minimumSize: const Size(double.infinity, 50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),  // Adjust radius here
              ),
            ),
            onPressed: () {
              // Your onPressed action here
            },
            child: const Text(
              'Remove model',
              style: TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }
}
