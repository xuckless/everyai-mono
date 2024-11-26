import 'package:flutter/material.dart';

class CustomForm extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController? nameController;
  final TextEditingController? emailController;
  final TextEditingController? passwordController;
  final TextEditingController? confirmPasswordController;

  final bool nameField;
  final bool email;
  final bool password;
  final bool confirmPassword;

  final VoidCallback? onSubmit;

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
      width: 350,
      child: Form(
        key: formKey,
        child: Column(
          children: [
            if (nameField)
              Column(
                children: [
                  TextFormField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: "Name",
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return "Please enter your name";
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) => onSubmit?.call(),
                  ),
                  const SizedBox(height: 30), // Adjustable space
                ],
              ),
            if (email)
              Column(
                children: [
                  TextFormField(
                    controller: emailController,
                    decoration: const InputDecoration(
                      labelText: "Email",
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return "Please enter your email";
                      }
                      if (!RegExp(r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$")
                          .hasMatch(value)) {
                        return "Please enter a valid email address";
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) => onSubmit?.call(),
                  ),
                  const SizedBox(height: 30), // Adjustable space
                ],
              ),
            if (password)
              Column(
                children: [
                  TextFormField(
                    controller: passwordController,
                    decoration: const InputDecoration(
                      labelText: "Password",
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    ),
                    obscureText: true,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return "Please enter your password";
                      }
                      if (value.length < 6) {
                        return "Password must be at least 6 characters long";
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) => onSubmit?.call(),
                  ),
                  const SizedBox(height: 30), // Adjustable space
                ],
              ),
            if (confirmPassword)
              Column(
                children: [
                  TextFormField(
                    controller: confirmPasswordController,
                    decoration: const InputDecoration(
                      labelText: "Confirm Password",
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    ),
                    obscureText: true,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return "Please confirm your password";
                      }
                      if (value != passwordController?.text) {
                        return "Passwords do not match";
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) => onSubmit?.call(),
                  ),
                  const SizedBox(height: 30), // Adjustable space
                ],
              ),
          ],
        ),
      ),
    );
  }

}
