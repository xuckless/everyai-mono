import 'package:flutter/material.dart';
import 'package:second_times_the_charm/models/global-resource/app_colors.dart';
import '../../models/chat_models.dart'; // Ensure correct path

/// A widget that displays a square library containing a list of chat models.
///
/// The `LibrarySquare` widget presents a titled container with a list of selectable
/// chat models. Each model is displayed with an image, name, and a `(-)` button to remove it
/// from "My Library" and move it back to the "Marketplace".
///
/// Selecting a model triggers a callback with the model's name and closes the drawer.
class LibrarySquare extends StatefulWidget {
  /// The title displayed at the top of the library square.
  final String title;

  /// Callback function invoked when a chat model is selected.
  ///
  /// The function receives the name of the selected chat model as a parameter.
  final Function(String) onModelSelected;

  /// Creates an instance of [LibrarySquare].
  ///
  /// - [title]: The title displayed at the top of the library square.
  /// - [onModelSelected]: The callback function triggered upon selecting a model.
  const LibrarySquare({
    super.key,
    required this.title,
    required this.onModelSelected,
  });

  @override
  _LibrarySquareState createState() => _LibrarySquareState();
}

class _LibrarySquareState extends State<LibrarySquare> {
  void _removeModel(String modelName) {
    setState(() {
      toggleModelStatus(modelName); // Updates the model's status in chatModelAddedStatus
    });
  }

  @override
  Widget build(BuildContext context) {
    // Filter chat models to only include those marked as true in chatModelAddedStatus
    final filteredChatModels = chatModels
        .where((chat) => chatModelAddedStatus[chat['name']] ?? false)
        .toList();

    return Container(
      width: 270,
      height: 317,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: AppColors.primary,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              widget.title,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: Colors.white,
                fontSize: 16,
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: filteredChatModels.length,
                itemBuilder: (context, index) {
                  final chat = filteredChatModels[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Row(
                      children: [
                        // Model image
                        ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: Image.asset(
                            chat['picture'],
                            width: 32,
                            height: 32,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(width: 8),

                        // Model name (tap to select)
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              widget.onModelSelected(chat['name']);
                              Navigator.pop(context);
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(color: AppColors.divider),
                                ),
                              ),
                              child: Text(
                                chat['name'],
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                  color: Colors.white70,
                                  fontSize: 18,
                                ),
                              ),
                            ),
                          ),
                        ),

                        // Remove button
                        IconButton(
                          onPressed: () => _removeModel(chat['name']),
                          icon: const Icon(
                            Icons.remove,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}