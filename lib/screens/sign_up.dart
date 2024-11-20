import 'package:flutter/material.dart';
import 'package:second_times_the_charm/widgets/custom_button.dart';
import 'package:second_times_the_charm/widgets/custom_form.dart';
import 'package:second_times_the_charm/widgets/default_app_bar.dart';
import '../models/sign_up_handler.dart';
import '../models/navigation.dart';
import 'home.dart';

class SignUpPage extends StatefulWidget {
  final String title;

  const SignUpPage({super.key, required this.title});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
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
      appBar: DefaultAppBar(
        subtitle: subtitle,
        actions: [],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                "Create Your Account",
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: CustomForm(
                  formKey: _formKey,
                  nameController: _nameController,
                  emailController: _emailController,
                  passwordController: _passwordController,
                  confirmPasswordController: _confirmPasswordController,
                  nameField: true,
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
              CustomButton(
                text: 'Sign Up',
                onPressed: _isLoading ? null : _handleSignUp,
                isLoading: _isLoading,
              ),
              const SizedBox(height: 16),
              TextButton(
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
    );
  }
}