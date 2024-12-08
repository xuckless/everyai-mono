// my_home_page.dart

import 'package:flutter/material.dart';
import 'package:second_times_the_charm/widgets/global-resource/custom_button.dart';
import 'package:second_times_the_charm/widgets/global-resource/custom_form.dart';
import 'package:second_times_the_charm/models/utils/navigation.dart';
import '../models/api/api_service.dart';
import 'chat_screen.dart';
import 'sign_up.dart';
import '../models/utils/login_handler.dart';

/// The main home page of the application where users can log in.
///
/// The `MyHomePage` widget provides a user interface for users to enter their
/// email and password to log in. It includes options for standard login and
/// Google login, as well as navigation to the sign-up page for new users.
///
/// This widget interacts with the [LoginHandler] to manage authentication
/// processes and uses [ApiService] to communicate with the backend API.
class MyHomePage extends StatefulWidget {
  /// The title of the home page, displayed in the app bar.
  final String title;

  /// Creates an instance of [MyHomePage].
  ///
  /// - [title]: The title displayed in the app bar.
  const MyHomePage({super.key, required this.title});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  /// Key to identify the form and manage its state.
  final _formKey = GlobalKey<FormState>();

  /// Controller for the email input field.
  final TextEditingController _emailController = TextEditingController();

  /// Controller for the password input field.
  final TextEditingController _passwordController = TextEditingController();

  /// Instance of [LoginHandler] to manage login operations.
  final LoginHandler _loginService = LoginHandler();

  /// Indicates whether a loading state is active (e.g., during API calls).
  bool _isLoading = false;

  /// Stores error messages to display to the user.
  String? _errorMessage;

  /// Callback to update the error message state.
  void setErrorMessage(String? message) {
    setState(() {
      _errorMessage = message;
    });
  }

  /// Callback to update the loading state.
  void setLoading(bool isLoading) {
    setState(() {
      _isLoading = isLoading;
    });
  }

  /// Subtitle displayed below the main title.
  final String subtitle = "Where every AI resides";

  /// Handles the standard login process.
  ///
  /// Currently, this method directly navigates to the [ChatScreen] without
  /// performing actual authentication. Uncomment the [LoginHandler] logic
  /// to enable real login functionality.
  void _handleLogin() {
    navigateToPage(context, const ChatScreen(title: "Chat Screen"));
    // Uncomment the following lines to enable real login functionality
    /*
    _loginService.handleLogin(
        context: context,
        formKey: _formKey,
        emailController: _emailController,
        passwordController: _passwordController,
        setErrorMessage: setErrorMessage,
        setLoading: setLoading);
    */
  }

  /// Handles the Google login process.
  ///
  /// Uses the [ApiService] to perform Google authentication. On successful
  /// login, navigates to the [ChatScreen]. Displays an error message if the
  /// login fails.
  void _handleGoogleLogin() async {
    final apiService = ApiService();

    try {
      await apiService.googleLogin();
      // Handle successful login, e.g., navigate to the HomeScreen
      navigateToPage(context, const ChatScreen(title: "Home Screen"));
    } catch (e) {
      // Log the error and display an error message to the user
      print("Google Login Failed: $e");
      setErrorMessage("Failed to log in with Google. Please try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF181C26), // Sets the background color
      resizeToAvoidBottomInset: false, // Prevents resizing when keyboard appears
      body: Stack(
        children: [
          // Positioned widget for the top title "EveryAI (beta)"
          Positioned(
            top: 150, // Distance from the top of the screen
            left: 0,
            right: 0,
            child: Text(
              "EveryAI (beta)",
              textAlign: TextAlign.center, // Centers the text horizontally
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: Colors.white, // Sets text color to white
              ),
            ),
          ),
          // Centered container holding the login form and buttons
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0), // Padding around the content
              child: Container(
                width: 365, // Width of the login container
                padding: const EdgeInsets.all(16.0), // Padding inside the container
                decoration: BoxDecoration(
                  color: const Color(0xFF181C26), // Background color
                  borderRadius: BorderRadius.circular(8), // Rounded corners
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2), // Shadow color
                      offset: const Offset(0, 2), // Shadow position
                      blurRadius: 4, // Shadow blur
                    ),
                    BoxShadow(
                      color: Colors.black.withOpacity(0.4), // Additional shadow
                      offset: const Offset(0, 8),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min, // Adjusts height to content
                  mainAxisAlignment: MainAxisAlignment.center, // Centers vertically
                  crossAxisAlignment: CrossAxisAlignment.center, // Centers horizontally
                  children: [
                    // Padding around the custom form
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: CustomForm(
                        formKey: _formKey,
                        emailController: _emailController,
                        passwordController: _passwordController,
                        nameField: false, // Hides the name field
                        email: true, // Shows the email field
                        password: true, // Shows the password field
                        confirmPassword: false, // Hides the confirm password field
                        onSubmit: _handleLogin, // Triggered on Enter key press
                      ),
                    ),
                    // Displays error messages if any
                    if (_errorMessage != null)
                      Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    // Login button
                    SizedBox(
                      width: 315, // Width matching the input fields
                      child: CustomButton(
                        color: const Color(0xFF2F60D9), // Button color
                        text: 'Login', // Button text
                        onPressed: _isLoading ? null : _handleLogin, // Disabled when loading
                        isLoading: _isLoading, // Shows loading indicator if true
                      ),
                    ),
                    const SizedBox(height: 16), // Spacing between buttons
                    const Text(
                      "or",
                      style: TextStyle(color: Colors.white), // Styled "or" text
                    ),
                    const SizedBox(height: 16), // Additional spacing
                    // Google login button
                    SizedBox(
                      width: 315, // Width matching the input fields
                      child: CustomButton(
                        color: const Color(0xFF2F1555), // Button color
                        text: "Login with Google", // Button text
                        onPressed: _isLoading ? null : _handleGoogleLogin, // Disabled when loading
                        isLoading: _isLoading, // Shows loading indicator if true
                        leadingIcon: Image.asset(
                          'assets/google_logo.png',
                          height: 24,
                          width: 24,
                        ), // Google logo icon
                      ),
                    ),
                    // Navigation to the Sign-Up page
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white, // Text color
                      ),
                      onPressed: () => navigateToPage(
                        context,
                        const SignUpPage(title: "Sign Up"),
                      ), // Navigates to Sign-Up page
                      child: const Text("Don't have an account? Sign Up"), // Button text
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    // Dispose of the controllers to free up resources
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}