import 'package:flutter/material.dart';

/// A customizable AppBar widget with enhanced layout and functionality.
///
/// The AppBar includes:
/// - A title on the left.
/// - A subtitle displayed in the center.
/// - A dropdown button for the pop-up menu on the right.
/// - Customizable actions and leading widgets.
class DefaultAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// The main title displayed on the AppBar.
  final String title;

  /// The subtitle displayed in the center of the AppBar.
  final String subtitle;

  /// A widget displayed as a pop-up when interacting with the dropdown button.
  final Widget? popUp;

  /// A list of widgets to display in the AppBar's action area.
  final List<Widget>? actions;

  /// A custom leading widget to replace the default leading behavior.
  final Widget? customLeading;

  /// Callback function triggered when the dropdown button is tapped.
  final VoidCallback? onPopUpTap;

  final String popUpText;

  /// Creates an instance of [DefaultAppBar].
  ///
  /// - [title]: The main title of the AppBar. Defaults to "EveryAI".
  /// - [subtitle]: The subtitle displayed in the center of the AppBar.
  /// - [popUp]: Optional widget for a pop-up menu.
  /// - [actions]: Optional widgets for the AppBar's action area.
  /// - [customLeading]: Optional custom widget for the leading position.
  /// - [onPopUpTap]: Callback for dropdown button tap events.
  const DefaultAppBar({
    super.key,
    this.title = "EveryAI",
    required this.subtitle,
    this.popUp,
    this.actions,
    this.customLeading,
    this.onPopUpTap,
    required this.popUpText,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      // Applies rounded corners to the bottom of the AppBar.
      borderRadius: const BorderRadius.only(
        bottomLeft: Radius.circular(16),
        bottomRight: Radius.circular(16),
      ),
      child: AppBar(
        // Leading widget, either custom or default behavior.
        leading: customLeading ??
          Builder(builder: (context) {
            if (Scaffold.hasDrawer(context)) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Scaffold.of(context).openDrawer(),
                child: Container(
                  alignment: Alignment.center,
                  height: kToolbarHeight,
                  width: 56,
                  child: Image.asset(
                    './assets/panel-right.png', // Drawer icon asset.
                    height: 20,
                    width: 20,
                    fit: BoxFit.contain,
                  ),
                ),
              );
            } else {
              return IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              );
            }
          }),

        titleSpacing: 0, // Removes default title spacing.
        backgroundColor: const Color(0xFF2A3041), // Sets AppBar background color.

        title: Row(
          children: [
            // Title on the left.
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onPrimary,
                    fontSize: 18,
                    height: 1.0,
                  ),
                ),
              ),
            ),
            // Subtitle in the center.
            Expanded(
              child: Align(
                alignment: Alignment.center,
                child: Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onPrimary,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          ],
        ),

        // Action widgets including the dropdown for pop-up menu.
        // Add this to actions in DefaultAppBar
        actions: [
          ...?actions, // Additional action widgets, if any.
          GestureDetector(
            onTap: onPopUpTap, // Triggers the dropdown button tap callback.
            child: Row(
              children: [
                Text(
                  popUpText, // Display the selected item's name
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onPrimary,
                    fontSize: 16,
                  ),
                ),
                const Icon(
                  Icons.arrow_drop_down, // Dropdown arrow icon.
                  color: Colors.white,
                ),
                const SizedBox(width: 12), // Adds spacing from the edge.
              ],
            ),
          ),
        ],
        toolbarHeight: preferredSize.height, // Sets the height of the AppBar.
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(75); // Defines AppBar size.
}