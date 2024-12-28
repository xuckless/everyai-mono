import 'package:flutter/material.dart';
import 'package:second_times_the_charm/models/utils/navigation.dart';
import 'package:second_times_the_charm/screens/account.dart';
import 'package:second_times_the_charm/screens/marketplace.dart';
import 'package:second_times_the_charm/widgets/my-library-widgets/chat-history.dart';
import 'dart:io';
import '../../models/global-resource/app_colors.dart';
import '../../models/utils/login_handler.dart';
import 'my_library.dart';

class DrawerComponent extends StatelessWidget {
  final Function(String) onModelSelected;
  final Function(int) onPressed;

  const DrawerComponent({
    super.key,
    required this.onModelSelected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final bool isIOS = Platform.isIOS;
    final loginHandler = LoginHandler(); // Create an instance of LoginHandler

    return Drawer(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
      ),
      child: Container(
        color: const Color(0xFF181C26),
        child: Column(
          children: [
            const SizedBox(height: 70),
            Center(
              child: Column(
                children: [
                  LibrarySquare(
                    title: "My Library",
                    onModelSelected: onModelSelected,
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () async {
                      await navigateTo(context, Marketplace(title: 'Marketplace'));
                      (context as Element).markNeedsBuild();
                    },
                    child: Container(
                      width: 270,
                      height: 45,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: const Color(0xFF2A3041),
                      ),
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.store,
                              color: Colors.white,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              "MarketPlace",
                              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                color: Colors.white,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ChatHistoryWidget(
                    onPressed: onPressed,
                  ),
                ],
              ),
            ),
            const Spacer(),
            const Divider(
              color: AppColors.divider,
              thickness: 1,
            ),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      await navigateTo(context, Account());
                      (context as Element).markNeedsBuild();
                    },
                    child: Container(
                      padding: EdgeInsets.all(isIOS ? 20 : 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          "Account",
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.white,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.logout, color: Colors.white),
                  onPressed: () async {
                    await loginHandler.handleLogout(context); // Call the logout logic
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
