import 'package:flutter/material.dart';
import 'api_service.dart';

class SignUpHandler {
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
    if (formKey.currentState!.validate()) {
      // Check if passwords match
      if (passwordController.text.trim() != confirmPasswordController.text.trim()) {
        showError("Passwords do not match.");
        return;
      }

      setLoading(true);

      final apiService = ApiService();
      final name = nameController.text.trim(); // Default name for now
      final email = emailController.text.trim();
      final password = passwordController.text.trim();

      try {
        final response = await apiService.signUp(name, email, password);
        if (response['access_token'] != null) {
          onSuccess(); // Trigger success callback
        } else {
          showError("Signup failed: ${response['message']}");
        }
      } catch (e) {
        showError("Failed to sign up: $e");
      } finally {
        setLoading(false);
      }
    }
  }
}