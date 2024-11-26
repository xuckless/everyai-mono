import 'package:flutter/material.dart';
import 'package:second_times_the_charm/widgets/custom_button.dart';
import 'package:second_times_the_charm/widgets/custom_form.dart';
import '../models/sign_up_handler.dart';
import '../models/navigation.dart';
import 'log_in.dart';

class SignUpPage extends StatefulWidget {
  final String title;

  const SignUpPage({super.key, required this.title});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();

  final SignUpHandler _signUpHandler = SignUpHandler();

  bool _isLoading = false;
  String? _errorMessage;

  void _showError(String? message) {
    setState(() {
      _errorMessage = message;
    });
  }

  void _onSuccess() {
    navigateToPage(context, const MyHomePage(title: "Login")); // Navigate to login on success
  }

  void _setLoading(bool isLoading) {
    setState(() {
      _isLoading = isLoading;
    });
  }

  final String subtitle = "Join EveryAI today!";

  void _handleSignUp() {
    _signUpHandler.validateAndSignUp(
      formKey: _formKey,
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
      backgroundColor: const Color(0xFF181C26),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // Top Positioned "EveryAI (beta)"
          Positioned(
            top: 150, // Distance from the top of the screen
            left: 0,
            right: 0,
            child: Text(
              "EveryAI (beta)",
              textAlign: TextAlign.center, // Center the text horizontally
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: Colors.white,
              ),
            ),
          ),
          // Centered content inside a rectangle
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Container(
                width: 365, // Width of the rectangle
                padding: const EdgeInsets.all(16.0), // Padding inside the rectangle
                decoration: BoxDecoration(
                  color: const Color(0xFF181C26), // Background color of the rectangle
                  borderRadius: BorderRadius.circular(8), // Rounded corners
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2), // Shadow color
                      offset: const Offset(0, 2), // Slight shadow at the top
                      blurRadius: 4, // Soft shadow appearance
                    ),
                    BoxShadow(
                      color: Colors.black.withOpacity(0.4), // Shadow color
                      offset: const Offset(0, 8), // More pronounced shadow at the bottom
                      blurRadius: 8, // Stronger blur for the bottom shadow
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min, // Adjust height to content
                  mainAxisAlignment: MainAxisAlignment.center, // Center vertically
                  crossAxisAlignment: CrossAxisAlignment.center, // Center horizontally
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: CustomForm(
                        formKey: _formKey,
                        emailController: _emailController,
                        passwordController: _passwordController,
                        confirmPasswordController: _confirmPasswordController,
                        nameField: false,
                        email: true,
                        password: true,
                        confirmPassword: true,
                        onSubmit: _handleSignUp, // Triggered on Enter
                      ),
                    ),
                    if (_errorMessage != null)
                      Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: 315, // Match the input field width
                      child: CustomButton(
                        color: const Color(0xFF2F60D9),
                        text: 'Sign Up',
                        onPressed: _isLoading ? null : _handleSignUp,
                        isLoading: _isLoading,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => navigateToPage(
                        context,
                        const MyHomePage(title: "Login"),
                      ),
                      child: const Text("Already have an account? Login"),
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
}
