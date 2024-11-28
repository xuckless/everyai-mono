import 'package:flutter/material.dart';

/// A customizable AppBar widget that provides a default styling and behavior.
///
/// This AppBar includes a title, subtitle, optional actions, and a customizable leading widget.
/// It also handles the display of a drawer or a back button based on the Scaffold's context.
class DefaultAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// The main title displayed on the AppBar.
  final String title;

  /// The subtitle displayed below the main title on the AppBar.
  final String subtitle;

  /// A list of widgets to display in the AppBar's action area.
  final List<Widget>? actions;

  /// A custom leading widget to replace the default leading behavior.
  final Widget? customLeading;

  /// Callback function triggered when the subtitle is tapped.
  final VoidCallback? onSubtitleTap;

  /// Creates an instance of [DefaultAppBar].
  ///
  /// - [title]: The main title of the AppBar. Defaults to "EveryAI".
  /// - [subtitle]: The subtitle displayed below the title.
  /// - [actions]: Optional widgets to display in the AppBar's action area.
  /// - [customLeading]: Optional custom widget for the leading position.
  /// - [onSubtitleTap]: Optional callback for subtitle tap events.
  const DefaultAppBar({
    super.key,
    this.title = "EveryAI",
    required this.subtitle,
    this.actions,
    this.customLeading,
    this.onSubtitleTap,
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
        // Determines the leading widget, either custom or default behavior.
        leading: customLeading ??
            Builder(builder: (context) {
              if (Scaffold.hasDrawer(context)) {
                // If a drawer is present, display a custom drawer icon.
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    Scaffold.of(context).openDrawer(); // Opens the drawer.
                  },
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
                // If no drawer, display a back button.
                return IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () {
                    Navigator.of(context).pop(); // Navigates back.
                  },
                );
              }
            }),

        titleSpacing: 0, // Removes default title spacing.
        title: Stack(
          children: [
            // Title aligned to the left.
            Align(
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
            // Subtitle centered and wrapped with GestureDetector for tap handling.
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onSubtitleTap, // Triggered when subtitle is tapped.
              child: Align(
                alignment: Alignment.center,
                child: Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onPrimary
                        .withOpacity(0.8),
                    fontSize: 14,
                    height: 1.0,
                  ),
                  overflow: TextOverflow.ellipsis, // Handles overflow with ellipsis.
                ),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF2A3041), // Sets AppBar background color.
        actions: actions, // Displays action widgets if provided.
        toolbarHeight: preferredSize.height, // Sets the height of the AppBar.
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(75); // Defines AppBar size.
}