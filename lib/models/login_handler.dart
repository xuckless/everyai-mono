import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:second_times_the_charm/models/navigation.dart';
import 'package:second_times_the_charm/screens/log_in.dart';
import 'api_service.dart';
import '../screens/home_screen.dart';

class LoginHandler {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  Future<void> handleLogin({
    required BuildContext context,
    required GlobalKey<FormState> formKey,
    required TextEditingController emailController,
    required TextEditingController passwordController,
    required Function(String?) setErrorMessage,
    required Function(bool) setLoading,
  }) async {
    if (formKey.currentState!.validate()) {
      setLoading(true);
      setErrorMessage(null);

      final apiService = ApiService();
      final email = emailController.text.trim();
      final password = passwordController.text.trim();

      try {
        final response = await apiService.login(email, password);
        if (response['success']) {
          // Store the token and navigate to chat screen
          await _secureStorage.write(
              key: "access_token", value: response['access_token']);
          navigateToPage(context, ChatScreen(title: "chat screen"));
        } else {
          setErrorMessage(response['message']);
        }
      } on Exception catch (e) {
        // Use the error message directly from the Exception thrown in `post`
        setErrorMessage(e.toString().replaceFirst('Exception: ', ''));
      } finally {
        setLoading(false);
      }
    }
  }

  Future<void> handleLogout(BuildContext context) async {
    await _secureStorage.delete(key: "access_token");
    navigateOneWay(context, MyHomePage(title: "Login"));
  }

}