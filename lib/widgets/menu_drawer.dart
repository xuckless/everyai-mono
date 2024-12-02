// drawer_component.dart

import 'package:flutter/material.dart';
import 'package:second_times_the_charm/models/navigation.dart';
import 'package:second_times_the_charm/screens/marketplace.dart';
import 'dart:io';
import 'my_library.dart';

/// A widget that represents the application's navigation drawer.
///
/// The `DrawerComponent` provides a sidebar navigation menu that includes:
/// - A `LibrarySquare` section for selecting chat models.
/// - A navigation option to the Marketplace.
/// - A Settings section.
///
/// It adapts padding based on the platform (iOS or others) to ensure consistent UI.
class DrawerComponent extends StatelessWidget {
  /// Callback function invoked when a chat model is selected from the `LibrarySquare`.
  final Function(String) onModelSelected;

  /// Creates an instance of [DrawerComponent].
  ///
  /// - [onModelSelected]: A required callback function triggered upon selecting a chat model.
  const DrawerComponent({
    Key? key,
    required this.onModelSelected,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Determines if the current platform is iOS for adaptive padding.
    final bool isIOS = Platform.isIOS;

    return Drawer(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero, // No border radius for the drawer
      ),
      child: Container(
        color: const Color(0xFF181C26), // Sets the background color of the drawer
        child: Column(
          children: [
            const SizedBox(height: 70), // Adds vertical space at the top
            Center(
              child: Column(
                children: [
                  // Integrates the LibrarySquare widget for chat model selection
                  LibrarySquare(
                    title: "My Library",
                    onModelSelected: onModelSelected, // Passes the callback to LibrarySquare
                  ),
                  const SizedBox(height: 16), // Adds spacing between LibrarySquare and Marketplace

                  // GestureDetector to handle navigation to the Marketplace page
                  GestureDetector(
                    onTap: () async {
                      await navigateTo(context, Marketplace(title: 'Marketplace'));
                      // Trigger a refresh for the LibrarySquare when returning
                      (context as Element).markNeedsBuild();
                    },
                    child: Container(
                      width: 270, // Sets the width of the Marketplace button
                      height: 45, // Sets the height of the Marketplace button
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8), // Rounds the corners
                        color: const Color(0xFF2A3041), // Sets the background color
                      ),
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min, // Wraps the row to its content
                          children: [
                            Icon(
                              Icons.store, // Icon representing the Marketplace
                              color: Colors.white, // Sets the icon color
                              size: 20, // Sets the icon size
                            ),
                            const SizedBox(width: 8), // Adds horizontal spacing between icon and text
                            Text(
                              "MarketPlace",
                              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                color: Colors.white, // Sets the text color
                                fontSize: 16, // Sets the font size
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(), // Pushes the Settings section to the bottom
            const Divider(
              color: Color(0xFF2A3041), // Sets the color of the divider
              thickness: 1, // Sets the thickness of the divider
            ),
            Container(
              padding: EdgeInsets.all(isIOS ? 16 : 8), // Adaptive padding based on platform
              child: Align(
                alignment: Alignment.centerLeft, // Aligns the Settings text to the left
                child: Text(
                  "Settings",
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white, // Sets the text color
                    fontSize: 16, // Sets the font size
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}