// sign_up_handler.dart

import 'package:flutter/material.dart';
import '../api/api_service.dart';
import '../api/auth_service.dart';

/// A handler class responsible for managing user registration processes,
/// including validating input data and communicating with the backend API.
class SignUpHandler {
  /// Handles the validation and sign-up process.
  ///
  /// This method validates the form inputs, ensures that passwords match,
  /// communicates with the [ApiService] to register the user, and triggers
  /// appropriate callbacks based on the response.
  ///
  /// - [formKey]: The key associated with the sign-up form to manage its state.
  /// - [nameController]: Controller for the name input field.
  /// - [emailController]: Controller for the email input field.
  /// - [passwordController]: Controller for the password input field.
  /// - [confirmPasswordController]: Controller for the confirm password input field.
  /// - [setLoading]: Callback to manage the loading state in the UI.
  /// - [showError]: Callback to display error messages in the UI.
  /// - [onSuccess]: Callback triggered upon successful sign-up.
  Future<void> validateAndSignUp({
    required GlobalKey<FormState> formKey,
    required TextEditingController nameController,
    required TextEditingController emailController,
    required TextEditingController passwordController,
    required TextEditingController confirmPasswordController,
    required Function(bool) setLoading,
    required Function(String) showError,
    required Function onSuccess,
  }) async {
    // Validate the form inputs
    if (formKey.currentState!.validate()) {
      // Check if passwords match
      if (passwordController.text.trim() != confirmPasswordController.text.trim()) {
        showError("Passwords do not match.");
        return;
      }

      setLoading(true); // Show loading indicator

      final apiService = ApiService();
      final authService = AuthService(apiService);
      final name = nameController.text.trim(); // Get and trim name input
      final email = emailController.text.trim(); // Get and trim email input
      final password = passwordController.text.trim(); // Get and trim password input

      try {
        // Attempt to sign up using the API service
        final response = await authService.signUp(name, email, password);
        if (response['access_token'] != null) {
          onSuccess(); // Trigger success callback
        } else {
          // Display error message returned by the API
          showError("Signup failed: ${response['message']}");
        }
      } catch (e) {
        // Handle any exceptions thrown during the sign-up process
        showError("Failed to sign up: $e");
      } finally {
        setLoading(false); // Hide loading indicator
      }
    }
  }
}