import 'package:flutter/material.dart';
import 'package:every_ai/models/utils/navigation.dart';
import 'package:every_ai/screens/log_in.dart';

// import '../../screens/account.dart';

final List<Map<String, dynamic>> settingsInfo = [
  {
    "name": "Personal Information",
    "func": (BuildContext context) => navigateToPage(context, MyHomePage(title: "home")),
  },
  {
    "name": "Dashboard",
    "func": (BuildContext context) => debugPrint("No navigation defined for Dashboard."),
  },
  {
    "name": "Model Preferences",
    "func": (BuildContext context) => debugPrint("No navigation defined for Dashboard."),
  },
  {
    "name": "Settings",
    "func": (BuildContext context) => debugPrint("No navigation defined for Dashboard."),
  },
];