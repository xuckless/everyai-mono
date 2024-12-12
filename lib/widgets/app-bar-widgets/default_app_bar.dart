import 'package:flutter/material.dart';
import 'package:second_times_the_charm/models/global-resource/app_colors.dart';

class DefaultAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final Widget? image; // Change image to a Widget to allow more flexibility
  final Widget? popUp;
  final List<Widget>? actions;
  final Widget? customLeading;
  final VoidCallback? onPopUpTap;
  final String popUpText;

  const DefaultAppBar({
    super.key,
    this.title = "EveryAI",
    this.image, // image is now optional and can be any widget
    this.popUp,
    this.actions,
    this.customLeading,
    this.onPopUpTap,
    required this.popUpText,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.only(
        bottomLeft: Radius.circular(16),
        bottomRight: Radius.circular(16),
      ),
      child: AppBar(
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
                      './assets/panel-right.png',
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
        titleSpacing: 0,
        backgroundColor: AppColors.primary,
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
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
            if (image != null)
              Row(
                mainAxisSize: MainAxisSize.min, // Ensure the row wraps tightly around its content
                children: [
                  ClipOval(
                    child: image!, // Display the widget passed as the image
                  ),
                  const SizedBox(width: 8), // Adjust this value for desired spacing
                  GestureDetector(
                    onTap: onPopUpTap,
                    child: Row(
                      children: [
                        Text(
                          popUpText,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onPrimary,
                            fontSize: 16,
                          ),
                        ),
                        const Icon(
                          Icons.arrow_drop_down,
                          color: Colors.white,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
        toolbarHeight: preferredSize.height,
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(75);
}