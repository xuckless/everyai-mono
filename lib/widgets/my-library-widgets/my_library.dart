import 'package:flutter/material.dart';
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
  /// Toggles the model status between "My Library" and "Marketplace".
  ///
  /// - [modelName]: The name of the model to toggle.
  /// Updates the `chatModelAddedStatus` map and triggers a rebuild.
  void _removeModel(String modelName) {
    setState(() {
      toggleModelStatus(modelName); // Updates the model's status
    });
  }

  @override
  Widget build(BuildContext context) {
    // Filters chat models to only include those marked as true in chatModelAddedStatus
    final filteredChatModels = chatModels
        .where((chat) => chatModelAddedStatus[chat['name']] ?? false)
        .toList();

    return Container(
      width: 270, // Sets the width of the library square
      height: 250, // Sets the height of the library square
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8), // Rounds the corners of the container
        color: const Color(0xFF2A3041), // Sets the background color
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0), // Adds padding inside the container
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, // Aligns children to the start
          children: [
            // Title of the library square
            Align(
              alignment: Alignment.center, // Centers the title horizontally
              child: Text(
                widget.title,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white, // Sets the text color to white
                  fontSize: 16, // Sets the font size
                ),
              ),
            ),
            const SizedBox(height: 8), // Adds vertical spacing below the title

            // Builds a list of chat models
            ListView.builder(
              padding: EdgeInsets.zero, // Removes default padding
              shrinkWrap: true, // Sizes the list to fit its children
              physics: const NeverScrollableScrollPhysics(), // Disables scrolling
              itemCount: filteredChatModels.length, // Number of items in the list
              itemBuilder: (context, index) {
                final chat = filteredChatModels[index]; // Retrieves the current chat model
                return Row(
                  children: [
                    // Displays the model's image
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20), // Rounds the image corners
                      child: Image.asset(
                        chat['picture'], // Path to the model's image asset
                        width: 32, // Sets the image width
                        height: 32, // Sets the image height
                        fit: BoxFit.cover, // Ensures the image scales to cover the space
                      ),
                    ),
                    const SizedBox(width: 8), // Adds spacing between image and text

                    // Displays the model's name as a separate button
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          widget.onModelSelected(chat["name"]); // Invokes the callback with the model name
                          Navigator.pop(context); // Closes the drawer
                        },
                        child: Text(
                          chat['name'], // The name of the chat model
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.white70, // Sets the text color to white with opacity
                            fontSize: 18, // Sets the font size
                          ),
                        ),
                      ),
                    ),

                    // Adds a `(-)` button to remove the model from "My Library"
                    IconButton(
                      onPressed: () {
                        _removeModel(chat['name']); // Calls the method to remove the model
                      },
                      icon: const Icon(
                        Icons.remove, // The `(-)` icon
                        color: Colors.white, // Sets the icon color to white
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}