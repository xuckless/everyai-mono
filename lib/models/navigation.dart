import 'package:flutter/material.dart';

void navigateToPage(BuildContext context, Widget page) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (context) => page),
  );
}

void navigateOneWay(BuildContext context, Widget page) {
  Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => page ),
  );
  Navigator.pop(context);
}

Future<void> navigateTo(BuildContext context, Widget page) async {
  await Navigator.push(
    context,
    MaterialPageRoute(builder: (context) => page),
  );
}