import 'package:flutter/material.dart';

class DefaultAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title; // Title of the AppBar
  final String subtitle; // Subtitle text
  final List<Widget>? actions; // Actions for the AppBar
  final Widget? customLeading; // Custom leading widget

  const DefaultAppBar({
    super.key,
    this.title = "EveryAI (Beta)", // Default title
    required this.subtitle,
    this.actions,
    this.customLeading,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.only(
        bottomLeft: Radius.circular(16), // Adjust the radius as needed
        bottomRight: Radius.circular(16),
      ),
      child: AppBar(
        leading: customLeading ??
            Padding(
              padding: EdgeInsets.zero, // Remove any extra padding
              child: GestureDetector(
                behavior: HitTestBehavior.opaque, // Ensure only the icon area is tappable
                onTap: () {
                  Scaffold.of(context).openDrawer(); // Manually open the drawer
                },
                child: Container(
                  alignment: Alignment.center,
                  height: kToolbarHeight, // Match AppBar height
                  width: 56, // Typical width for leading icons
                  child: Image.asset(
                    './assets/panel-right.png',
                    height: 20,
                    width: 20,
                    fit: BoxFit.contain,
                  ),
                ),
              ),

            ),

        titleSpacing: 0, // Ensures no spacing between leading and title
        title: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: Theme.of(context).colorScheme.onPrimary,
                fontSize: 18, // Adjust size as needed
              ),
            ),
            if (subtitle.isNotEmpty)
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onPrimary.withOpacity(0.8),
                      fontSize: 14, // Adjust size as needed
                    ),
                    overflow: TextOverflow.ellipsis, // Handles long text gracefully
                  ),
                ),
              ),
          ],
        ),
        backgroundColor: const Color(0xFF2A3041),
        actions: actions,
        toolbarHeight: preferredSize.height, // Set custom toolbar height
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(75); // Custom height
}
