import 'package:flutter/material.dart';
import 'package:second_times_the_charm/widgets/custom_button.dart';
import 'package:second_times_the_charm/widgets/custom_form.dart';
import 'package:second_times_the_charm/models/navigation.dart';
import 'package:second_times_the_charm/widgets/default_app_bar.dart';
import '../models/api_service.dart';
import 'chat_screen.dart';
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
      appBar: DefaultAppBar(
        subtitle: subtitle,
        actions: [

        ],
      ),


      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [

              Text(
                "Welcome to EveryAI (beta)", style: Theme.of(context).textTheme.headlineMedium,
              ),



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
              const SizedBox(height: 16),


              CustomButton(
                text: 'Login',
                onPressed: _isLoading ? null : _handleLogin,
                isLoading: _isLoading,
              ),

              TextButton(
                onPressed: () => navigateToPage(context, const SignUpPage(title: "Sign Up")),
                child: const Text("Don't have an account? Sign Up"),
              ),

              CustomButton(
                text: "Login with google",
                onPressed: _isLoading ? null : _handleGoogleLogin,
                isLoading: _isLoading,
              ),
            ],
          )
        ),
      ),
    );
  }
}
