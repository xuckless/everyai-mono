// library_square.dart

import 'package:flutter/material.dart';
import '../models/chat_models.dart'; // Ensure correct path

/// A widget that displays a square library containing a list of chat models.
///
/// The `LibrarySquare` widget presents a titled container with a list of selectable
/// chat models. Each model is displayed with an image and name, and selecting a
/// model triggers a callback with the model's name.
class LibrarySquare extends StatelessWidget {
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
    Key? key,
    required this.title,
    required this.onModelSelected,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
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
            Align(
              alignment: Alignment.center, // Centers the title horizontally
              child: Text(
                title,
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
              itemCount: chatModels.length, // Number of items in the list
              itemBuilder: (context, index) {
                final chat = chatModels[index]; // Retrieves the current chat model
                return GestureDetector(
                  onTap: () {
                    onModelSelected(chat["name"]); // Invokes the callback with the model name
                  },
                  child: Column(
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center, // Centers content vertically
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(20), // Rounds the image corners
                            child: Image.asset(
                              chat['picture'], // Displays the chat model's image
                              width: 32, // Sets the image width
                              height: 32, // Sets the image height
                              fit: BoxFit.cover, // Scales the image to cover the space
                            ),
                          ),
                          const SizedBox(width: 8), // Adds horizontal spacing between image and text
                          Expanded(
                            child: Text(
                              chat['name'], // Displays the chat model's name
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Colors.white70, // Sets text color with opacity
                                fontSize: 18, // Sets the font size
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12), // Adds vertical spacing between items
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}