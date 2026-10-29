import 'package:flutter/material.dart';

class CustomButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final Color? color;
  final Size? minimumSize;
  final bool isLoading;
  final Widget? leadingIcon;

  const CustomButton({
    super.key,
    required this.text,
    this.onPressed,
    this.color,
    this.minimumSize,
    this.isLoading = false,
    this.leadingIcon,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: isLoading ? null : onPressed, // Disable button when loading
      style: ElevatedButton.styleFrom(
        minimumSize: minimumSize ?? const Size(120, 40), // Default size
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8), // Rounded corners
        ),
        backgroundColor: color ?? Theme.of(context).colorScheme.primary, // Default color
      ),
      child: isLoading
          ? SizedBox(
        width: 20, // Ensures the indicator fits inside the button
        height: 20,
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation(Colors.white),
          strokeWidth: 2.0, // Adjust thickness
        ),
      )
          : Row(
        mainAxisSize: MainAxisSize.min, // Adjusts to content size
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (leadingIcon != null) ...[
            leadingIcon!,
            const SizedBox(width: 8), // Spacing between icon and text
          ],
          Text(
            text,
            style: const TextStyle(
              color: Colors.white, // Button text color
            ),
          ),
        ],
      ),
    );
  }
}