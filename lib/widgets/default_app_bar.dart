import 'package:flutter/material.dart';

class DefaultAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final String subtitle;
  final List<Widget>? actions;
  final Widget? customLeading;
  final VoidCallback? onSubtitleTap;

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
      borderRadius: const BorderRadius.only(
        bottomLeft: Radius.circular(16),
        bottomRight: Radius.circular(16),
      ),
      child: AppBar(
        leading: customLeading ??
            Builder(builder: (context){
              if (Scaffold.hasDrawer(context)) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    Scaffold.of(context).openDrawer();
                  },
                  child: Container(
                    alignment: Alignment.center,
                    height: kToolbarHeight,
                    width: 56,
                    child: Image.asset(
                      './assets/panel-right.png',
                      height: 20,
                      width: 20,
                      fit: BoxFit.contain,
                    )
                  ),
                );
              } else {
                return IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                );
              }
            }),


        titleSpacing: 0,
        title: Stack(
          children: [
            // Title aligned to the left
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
            // Subtitle centered and wrapped with GestureDetector
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onSubtitleTap,
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
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF2A3041),
        actions: actions,
        toolbarHeight: preferredSize.height,
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(75);
}
