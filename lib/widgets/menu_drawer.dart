import 'package:flutter/material.dart';
import 'dart:io';
import 'myLibrary.dart';

class DrawerComponent extends StatelessWidget {
  final Function(String) onModelSelected;

  const DrawerComponent({
    Key? key,
    required this.onModelSelected,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final bool isIOS = Platform.isIOS;

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
                    onModelSelected: onModelSelected, // Pass the callback to LibrarySquare
                  ),
                  const SizedBox(height: 16),
                  Container(
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
                            Icons.store, // Choose the icon you want
                            color: Colors.white,
                            size: 20,
                          ),
                          const SizedBox(width: 8), // Add some space between the icon and the text
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
                  )
                ],
              ),
            ),
            const Spacer(),
            const Divider(
              color: Color(0xFF2A3041),
              thickness: 1,
            ),
            Container(
              padding: EdgeInsets.all(isIOS ? 16 : 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Settings",
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white,
                    fontSize: 16,
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

