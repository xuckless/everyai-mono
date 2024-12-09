import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/log_in.dart';

/// The entry point of the Flutter application.
void main() {
  // Runs the MyApp widget and sets up the system UI overlay style.
  runApp(const MyApp());

  // Sets the color of the system navigation bar to match the app's primary color.
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    systemNavigationBarColor: Color(0xFF181C26), // Match with your app's primary color
  ));
}

/// The root widget of the application.
class MyApp extends StatelessWidget {
  /// Creates an instance of MyApp.
  const MyApp({super.key});

  /// Builds the widget tree for the application.
  ///
  /// This method is responsible for creating and returning the root [MaterialApp]
  /// widget, which defines the overall structure and theme of the application.
  ///
  /// [context] is the build context, which contains information about the location
  /// of this widget in the widget tree. It's not directly used in this method but
  /// is required by the [build] method signature.
  ///
  /// Returns a [Widget], specifically a [MaterialApp], which serves as the root
  /// of the application's widget tree. This [MaterialApp] includes the app's title,
  /// theme configuration, and the initial route (home screen).
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // The title of the application.
      title: 'Flutter Demo',

      // Defines the theme of the application using a color scheme.
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF181C26), // Primary color seed
          secondary: Colors.amber,      // Secondary color
        ),
        useMaterial3: true, // Enables Material Design 3
      ),

      // Sets the home screen of the application to MyHomePage.
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}