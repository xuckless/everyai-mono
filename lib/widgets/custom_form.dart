import 'package:flutter/material.dart';

/// A customizable form widget that can include various input fields such as
/// Name, Email, Password, and Confirm Password.
///
/// This widget allows for flexible configuration by enabling or disabling specific
/// fields based on the provided parameters. It also handles validation and submission
/// callbacks.
class CustomForm extends StatelessWidget {
  /// A global key that uniquely identifies the [Form] widget and allows validation
  /// of the form.
  final GlobalKey<FormState> formKey;

  /// Controller for the Name input field.
  final TextEditingController? nameController;

  /// Controller for the Email input field.
  final TextEditingController? emailController;

  /// Controller for the Password input field.
  final TextEditingController? passwordController;

  /// Controller for the Confirm Password input field.
  final TextEditingController? confirmPasswordController;

  /// Determines whether to display the Name input field.
  final bool nameField;

  /// Determines whether to display the Email input field.
  final bool email;

  /// Determines whether to display the Password input field.
  final bool password;

  /// Determines whether to display the Confirm Password input field.
  final bool confirmPassword;

  /// Callback function triggered upon form submission.
  final VoidCallback? onSubmit;

  /// Creates an instance of [CustomForm].
  ///
  /// - [formKey]: A required key to manage the form state.
  /// - [nameController]: Optional controller for the Name field.
  /// - [emailController]: Optional controller for the Email field.
  /// - [passwordController]: Optional controller for the Password field.
  /// - [confirmPasswordController]: Optional controller for the Confirm Password field.
  /// - [nameField]: Determines if the Name field is displayed.
  /// - [email]: Determines if the Email field is displayed.
  /// - [password]: Determines if the Password field is displayed.
  /// - [confirmPassword]: Determines if the Confirm Password field is displayed.
  /// - [onSubmit]: Optional callback for form submission.
  const CustomForm({
    super.key,
    required this.formKey,
    this.nameController,
    this.emailController,
    this.passwordController,
    this.confirmPasswordController,
    required this.nameField,
    required this.email,
    required this.password,
    required this.confirmPassword,
    this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 350, // Sets the width of the form container
      child: Form(
        key: formKey, // Associates the form with the provided key
        child: Column(
          children: [
            // Conditionally display the Name field
            if (nameField)
              Column(
                children: [
                  TextFormField(
                    controller: nameController, // Binds the controller
                    decoration: const InputDecoration(
                      labelText: "Name",
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(),
                      contentPadding:
                      EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    ),
                    validator: (value) {
                      // Validates that the name is not empty
                      if (value == null || value.isEmpty) {
                        return "Please enter your name";
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) =>
                        onSubmit?.call(), // Triggers submission on enter
                  ),
                  const SizedBox(height: 30), // Adds space below the field
                ],
              ),
            // Conditionally display the Email field
            if (email)
              Column(
                children: [
                  TextFormField(
                    controller: emailController, // Binds the controller
                    decoration: const InputDecoration(
                      labelText: "Email",
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(),
                      contentPadding:
                      EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    ),
                    validator: (value) {
                      // Validates that the email is not empty and follows a pattern
                      if (value == null || value.isEmpty) {
                        return "Please enter your email";
                      }
                      if (!RegExp(
                          r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$")
                          .hasMatch(value)) {
                        return "Please enter a valid email address";
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) =>
                        onSubmit?.call(), // Triggers submission on enter
                  ),
                  const SizedBox(height: 30), // Adds space below the field
                ],
              ),
            // Conditionally display the Password field
            if (password)
              Column(
                children: [
                  TextFormField(
                    controller: passwordController, // Binds the controller
                    decoration: const InputDecoration(
                      labelText: "Password",
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(),
                      contentPadding:
                      EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    ),
                    obscureText: true, // Hides the input for password security
                    validator: (value) {
                      // Validates that the password is not empty and meets length criteria
                      if (value == null || value.isEmpty) {
                        return "Please enter your password";
                      }
                      if (value.length < 6) {
                        return "Password must be at least 6 characters long";
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) =>
                        onSubmit?.call(), // Triggers submission on enter
                  ),
                  const SizedBox(height: 30), // Adds space below the field
                ],
              ),
            // Conditionally display the Confirm Password field
            if (confirmPassword)
              Column(
                children: [
                  TextFormField(
                    controller: confirmPasswordController, // Binds the controller
                    decoration: const InputDecoration(
                      labelText: "Confirm Password",
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(),
                      contentPadding:
                      EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    ),
                    obscureText: true, // Hides the input for password security
                    validator: (value) {
                      // Validates that the confirmation matches the original password
                      if (value == null || value.isEmpty) {
                        return "Please confirm your password";
                      }
                      if (value != passwordController?.text) {
                        return "Passwords do not match";
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) =>
                        onSubmit?.call(), // Triggers submission on enter
                  ),
                  const SizedBox(height: 30), // Adds space below the field
                ],
              ),
          ],
        ),
      ),
    );
  }
}