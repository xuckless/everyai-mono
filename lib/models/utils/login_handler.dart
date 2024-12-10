//./lib/models/utils/login_handler.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:second_times_the_charm/models/utils/navigation.dart';
import 'package:second_times_the_charm/screens/log_in.dart';
import '../api/api_service.dart';
import '../../screens/chat_screen.dart';
import 'TokenManager.dart';

/// A handler class responsible for managing user authentication processes,
/// including login, logout, and token validation functionalities.
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
      setLoading(true);
      setErrorMessage(null);

      final apiService = ApiService();
      final email = emailController.text.trim();
      final password = passwordController.text.trim();

      try {
        // Login via API
        final response = await apiService.login(email, password);
        if (response['success']) {
          // Store tokens
          TokenManager().setAccessToken(response['access_token']);
          await const FlutterSecureStorage().write(
            key: "refresh_token",
            value: response['refresh_token'],
          );

          // Navigate to the HomeScreen
          navigateToPage(context, ChatScreen(title: "Home screen"));
        } else {
          // Display the error message returned by the API
          setErrorMessage(response['message']);
        }
      } on Exception catch (e) {
        // Handle exceptions
        setErrorMessage(e.toString().replaceFirst('Exception: ', ''));
      } finally {
        setLoading(false); // Hide loading indicator
      }
    }
  }



  Future<bool> validateTokenLocally() async {
    try {
      // Check if access token in memory is valid
      if (TokenManager().isAccessTokenValid()) {
        print("Access token is valid");
        return true;
      }

      // Check if refresh token exists and is valid
      final refreshToken = await const FlutterSecureStorage().read(key: "refresh_token");
      final refreshTokenExpiry = await const FlutterSecureStorage().read(key: "refresh_token_expiry");

      if (refreshToken == null || refreshTokenExpiry == null) {
        print("No refresh token or expiry found");
        return false; // Redirect to login
      }

      final DateTime expiryDate = DateTime.parse(refreshTokenExpiry);
      if (DateTime.now().isAfter(expiryDate)) {
        print("Refresh token has expired");
        // Delete expired token
        await const FlutterSecureStorage().delete(key: "refresh_token");
        await const FlutterSecureStorage().delete(key: "refresh_token_expiry");
        return false; // Redirect to login
      }

      print("Retrieved refresh token: $refreshToken");
      print("Refresh token is still valid");

      // Attempt to refresh the access token
      final apiService = ApiService();
      final isRefreshed = await apiService.refreshAccessToken();
      return isRefreshed;
    } catch (e) {
      print("Error during token validation: $e");
      return false;
    }
  }





  /// Handles the logout process by deleting the stored access token
  /// and navigating back to the login screen.
  ///
  /// - [context]: The build context used for navigation.
  Future<void> handleLogout(BuildContext context) async {
    // Clear the access token from memory
    TokenManager().clearAccessToken();

    // Delete the refresh token from secure storage
    await const FlutterSecureStorage().delete(key: "refresh_token");

    // Redirect to the login screen
    navigateOneWay(context, const MyHomePage(title: "Login"));

    print("User logged out successfully.");
  }


  /// Handles app startup logic by validating the token and navigating accordingly.
  Future<void> handleAppStartup(BuildContext context) async {
    final isValidToken = await validateTokenLocally();

    if (isValidToken) {
      // Navigate to the ChatScreen if the token is valid
      navigateToPage(context, ChatScreen(title: "Home screen"));
    } else {
      // Redirect to the login screen if the token is invalid
      navigateOneWay(context, MyHomePage(title: "Login"));
    }
  }
}
