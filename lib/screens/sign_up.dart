// sign_up_page.dart

import 'package:flutter/material.dart';
import 'package:second_times_the_charm/widgets/custom_button.dart';
import 'package:second_times_the_charm/widgets/custom_form.dart';
import '../models/sign_up_handler.dart';
import '../models/navigation.dart';
import 'log_in.dart';

/// A stateful widget that represents the sign-up page of the application.
///
/// The `SignUpPage` widget provides a user interface for new users to create an
/// account by entering their name, email, password, and confirming their password.
/// It interacts with the [SignUpHandler](sign_up_handler.md) to manage the
/// registration process, including form validation, API communication, and
/// handling success or error responses.
class SignUpPage extends StatefulWidget {
  /// The title displayed in the app bar.
  final String title;

  /// Creates an instance of [SignUpPage].
  ///
  /// - [title]: The title displayed in the app bar.
  const SignUpPage({super.key, required this.title});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  /// Key to identify the form and manage its state.
  final _formKey = GlobalKey<FormState>();

  /// Controller for the name input field.
  final TextEditingController _nameController = TextEditingController();

  /// Controller for the email input field.
  final TextEditingController _emailController = TextEditingController();

  /// Controller for the password input field.
  final TextEditingController _passwordController = TextEditingController();

  /// Controller for the confirm password input field.
  final TextEditingController _confirmPasswordController =
  TextEditingController();

  /// Instance of [SignUpHandler] to manage sign-up operations.
  final SignUpHandler _signUpHandler = SignUpHandler();

  /// Indicates whether a loading state is active (e.g., during API calls).
  bool _isLoading = false;

  /// Stores error messages to display to the user.
  String? _errorMessage;

  /// Callback to update the error message state.
  void _showError(String? message) {
    setState(() {
      _errorMessage = message;
    });
  }

  /// Callback triggered upon successful sign-up.
  ///
  /// Navigates the user to the [MyHomePage](log_in.md) (Login page).
  void _onSuccess() {
    navigateToPage(context, const MyHomePage(title: "Login")); // Navigate to login on success
  }

  /// Callback to update the loading state.
  void _setLoading(bool isLoading) {
    setState(() {
      _isLoading = isLoading;
    });
  }

  /// Subtitle displayed below the main title.
  final String subtitle = "Join EveryAI today!";

  /// Handles the sign-up process by invoking the [SignUpHandler].
  ///
  /// This method validates the form, ensures that passwords match, communicates
  /// with the backend API to register the user, and navigates to the login page
  /// upon successful registration.
  void _handleSignUp() {
    _signUpHandler.validateAndSignUp(
      formKey: _formKey,
      nameController: _nameController,
      emailController: _emailController,
      passwordController: _passwordController,
      confirmPasswordController: _confirmPasswordController,
      setLoading: _setLoading,
      showError: _showError,
      onSuccess: _onSuccess,
    );
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
          // Centered container holding the sign-up form and buttons
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0), // Padding around the content
              child: Container(
                width: 365, // Width of the sign-up container
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
                        nameController: _nameController,
                        emailController: _emailController,
                        passwordController: _passwordController,
                        confirmPasswordController: _confirmPasswordController,
                        nameField: true, // Shows the name field
                        email: true, // Shows the email field
                        password: true, // Shows the password field
                        confirmPassword: true, // Shows the confirm password field
                        onSubmit: _handleSignUp, // Triggered on Enter key press
                      ),
                    ),
                    // Displays error messages if any
                    if (_errorMessage != null)
                      Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    // Sign Up button
                    SizedBox(
                      width: 315, // Width matching the input fields
                      child: CustomButton(
                        color: const Color(0xFF2F60D9), // Button color
                        text: 'Sign Up', // Button text
                        onPressed: _isLoading ? null : _handleSignUp, // Disabled when loading
                        isLoading: _isLoading, // Shows loading indicator if true
                      ),
                    ),
                    const SizedBox(height: 16), // Spacing between buttons
                    // Navigation to the Login page
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white, // Text color
                      ),
                      onPressed: () => navigateToPage(
                        context,
                        const MyHomePage(title: "Login"),
                      ), // Navigates to Login page
                      child: const Text("Already have an account? Login"), // Button text
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
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }
}