import 'package:flutter/material.dart';
import 'package:second_times_the_charm/screens/home.dart';
import '../models/api_service.dart';

class SignUpPage extends StatefulWidget {
  final String title;

  const SignUpPage({super.key, required this.title});

  State<SignUpPage> createState() => _SignUpState();
}

class _SignUpState extends State<SignUpPage> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  void _validateAndSignUp() async {
    if (_formKey.currentState!.validate()) {
      final apiService = ApiService();
      final email = _emailController.text.trim();
      final password = _passwordController.text.trim();

      try {
        final response = await apiService.signUp(email, password);
        if (response['message'] == "User created successfully") {
          _gotoHomePage(context); // Navigate to the login page
        } else {
          _showError("Signup failed: ${response['message']}");
        }
      } catch (e) {
        _showError("Failed to sign up: $e");
      }
    }
  }

  void _showError(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Error"),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  void _gotoHomePage(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => MyHomePage(title: 'Login Page')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("EveryAI (Beta)"),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        centerTitle: true,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              "Sign Up Today!",
              style: Theme.of(context).textTheme.headlineMedium,
            ),

            // Form Fields
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 380,
                maxHeight: 310,
                minWidth: 150,
                minHeight: 75,
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextFormField(
                      controller: _emailController,
                      decoration: const InputDecoration(
                        labelText: "Email",
                        border: UnderlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter your email';
                        }
                        if (!RegExp(r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$")
                            .hasMatch(value)) {
                          return 'Please enter a valid email address';
                        }
                        return null;
                      },
                    ),
                    TextFormField(
                      controller: _passwordController,
                      decoration: const InputDecoration(
                        labelText: "Password",
                        border: UnderlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter your password';
                        }
                        if (value.length < 6) {
                          return 'Password must be at least 6 characters long';
                        }
                        return null;
                      },
                      obscureText: true,
                    ),
                  ],
                ),
              ),
            ),

            // Sign Up Button
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxHeight: 50,
                maxWidth: 250,
              ),
              child: ElevatedButton(
                onPressed: _validateAndSignUp,
                child: const Text("Sign Up"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
