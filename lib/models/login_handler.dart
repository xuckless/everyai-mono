// login_handler.dart

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:second_times_the_charm/models/navigation.dart';
import 'package:second_times_the_charm/screens/log_in.dart';
import 'api_service.dart';
import '../screens/chat_screen.dart';

/// A handler class responsible for managing user authentication processes,
/// including login and logout functionalities.
///
/// The `LoginHandler` class utilizes [FlutterSecureStorage] to securely store
/// access tokens and interacts with an [ApiService] to communicate with the backend.
class LoginHandler {
  /// An instance of [FlutterSecureStorage] for securely storing sensitive data.
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  /// Handles the login process by validating form inputs, communicating with
  /// the authentication API, storing the access token upon successful login,
  /// and navigating to the home screen.
  ///
  /// - [context]: The build context used for navigation and displaying UI elements.
  /// - [formKey]: The key associated with the login form to manage its state.
  /// - [emailController]: Controller for the email input field.
  /// - [passwordController]: Controller for the password input field.
  /// - [setErrorMessage]: Callback to set error messages in the UI.
  /// - [setLoading]: Callback to manage the loading state in the UI.
  Future<void> handleLogin({
    required BuildContext context,
    required GlobalKey<FormState> formKey,
    required TextEditingController emailController,
    required TextEditingController passwordController,
    required Function(String?) setErrorMessage,
    required Function(bool) setLoading,
  }) async {
    // Validate the form inputs
    if (formKey.currentState!.validate()) {
      setLoading(true); // Show loading indicator
      setErrorMessage(null); // Clear any existing error messages

      final apiService = ApiService(); // Initialize the API service
      final email = emailController.text.trim(); // Get and trim email input
      final password = passwordController.text.trim(); // Get and trim password input

      try {
        // Attempt to log in using the API service
        final response = await apiService.login(email, password);
        if (response['success']) {
          // If login is successful, store the access token securely
          await _secureStorage.write(
              key: "access_token", value: response['access_token']);
          // Navigate to the HomeScreen
          navigateToPage(context, HomeScreen(title: "Home screen"));
        } else {
          // If login fails, display the error message returned by the API
          setErrorMessage(response['message']);
        }
      } on Exception catch (e) {
        // Handle any exceptions thrown during the login process
        setErrorMessage(e.toString().replaceFirst('Exception: ', ''));
      } finally {
        setLoading(false); // Hide loading indicator
      }
    }
  }

  /// Handles the logout process by deleting the stored access token
  /// and navigating back to the login screen.
  ///
  /// - [context]: The build context used for navigation.
  Future<void> handleLogout(BuildContext context) async {
    await _secureStorage.delete(key: "access_token"); // Remove the access token
    // Navigate back to the MyHomePage (Login screen) without the ability to return
    navigateOneWay(context, MyHomePage(title: "Login"));
  }
}