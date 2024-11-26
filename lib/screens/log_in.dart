import 'package:flutter/material.dart';
import 'package:second_times_the_charm/widgets/custom_button.dart';
import 'package:second_times_the_charm/widgets/custom_form.dart';
import 'package:second_times_the_charm/models/navigation.dart';
import '../models/api_service.dart';
import 'home_screen.dart';
import 'sign_up.dart';
import '../models/login_handler.dart';

class MyHomePage extends StatefulWidget {
  final String title;

  const MyHomePage({super.key, required this.title});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  final LoginHandler _loginService = LoginHandler();

  bool _isLoading = false;
  String? _errorMessage;

  void setErrorMessage(String? message) {
    setState(() {
      _errorMessage = message;
    });
  }

  void setLoading(bool isLoading) {
    setState(() {
      _isLoading = isLoading;
    });
  }

  final String subtitle = "Where every AI resides";

  void _handleLogin() {
    navigateToPage(context, const ChatScreen(title: "Chat Screen"));
    // _loginService.handleLogin(
    //     context: context,
    //     formKey: _formKey,
    //     emailController: _emailController,
    //     passwordController: _passwordController,
    //     setErrorMessage: setErrorMessage,
    //     setLoading: setLoading);
  }

  void _handleGoogleLogin() async {
    final apiService = ApiService();

    try {
      await apiService.googleLogin();
      // Handle successful login, e.g., navigate to the next screen
      navigateToPage(context, const ChatScreen(title: "Chat Screen"));
    } catch (e) {
      print("Google Login Failed: $e");
      setErrorMessage("Failed to log in with Google. Please try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF181C26),
      resizeToAvoidBottomInset: false, // Prevent content from resizing when keyboard appears
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
                        nameField: false,
                        email: true,
                        password: true,
                        confirmPassword: false,
                        onSubmit: _handleLogin, // Triggered on Enter
                      ),
                    ),
                    if (_errorMessage != null)
                      Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    SizedBox(
                      width: 315, // Match the input field width
                      child: CustomButton(
                        color: const Color(0xFF2F60D9),
                        text: 'Login',
                        onPressed: _isLoading ? null : _handleLogin,
                        isLoading: _isLoading,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      "or",
                      style: TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: 315, // Match the input field width
                      child: CustomButton(
                        color: const Color(0xFF2F1555),
                        text: "Login with Google",
                        onPressed: _isLoading ? null : _handleGoogleLogin,
                        isLoading: _isLoading,
                        leadingIcon: Image.asset('assets/google_logo.png', height: 24, width: 24),
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => navigateToPage(
                        context,
                        const SignUpPage(title: "Sign Up"),
                      ),
                      child: const Text("Don't have an account? Sign Up"),
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
