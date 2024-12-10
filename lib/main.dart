//./main.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/utils/login_handler.dart';
import 'screens/log_in.dart';
import 'screens/chat_screen.dart';

/// The entry point of the Flutter application.
void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // Ensure bindings are initialized

  final loginHandler = LoginHandler();
  final Widget initialScreen = await determineInitialScreen(loginHandler);

  runApp(MyApp(initialScreen: initialScreen));

  // Set the color of the system navigation bar
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    systemNavigationBarColor: Color(0xFF181C26), // Match the app's theme
  ));
}

/// Determines the initial screen based on token validation and expiration.
Future<Widget> determineInitialScreen(LoginHandler loginHandler) async {
  try {
    final isValidToken = await loginHandler.validateTokenLocally();

    if (isValidToken) {
      print("Valid token found. Redirecting to ChatScreen.");
      return ChatScreen(title: "Home screen");
    } else {
      print("No valid token found. Redirecting to Login.");
      return const MyHomePage(title: 'Login');
    }
  } catch (e) {
    print("Error determining initial screen: $e");
    return const MyHomePage(title: 'Login');
  }
}

/// The root widget of the application.
class MyApp extends StatelessWidget {
  final Widget initialScreen;

  const MyApp({super.key, required this.initialScreen});

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
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF181C26),
          secondary: Colors.amber,
        ),
        useMaterial3: true,
      ),
      home: initialScreen,
    );
  }
}
