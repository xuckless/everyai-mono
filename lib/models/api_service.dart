//./lib/models/api_service.dart

import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:google_sign_in/google_sign_in.dart';
import 'dart:io';

class ApiService {
  // List of potential base URLs for the API
  final List<String> baseUrls = [
    'http://10.0.2.2:8000', // For Android emulator
    'http://127.0.0.1:8000', // For iOS simulator
    'http://localhost:8000', //fallback
  ];

  String? _cachedBaseUrl;

  ApiService();

  // Fetch the available base URL
  Future<String> _getAvailableBaseUrl() async {
    // Return the cached base URL if it's set
    if (_cachedBaseUrl != null) {
      return _cachedBaseUrl!;
    }

    // Check each base URL in the list
    for (String url in baseUrls) {
      if (await _isServerAvailable(url)) {
        _cachedBaseUrl = url; // Cache the successful base URL
        return url;
      }
    }

    throw Exception('No available base URLs');
  }

  // Method to check if the server is available
  Future<bool> _isServerAvailable(String url) async {
    try {
      final response = await http
          .get(Uri.parse('$url/ping'))
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // Generalized POST method for API requests
  Future<dynamic> post(String endpoint, Map<String, dynamic> body) async {
    String baseUrl = await _getAvailableBaseUrl();
    final url = Uri.parse('$baseUrl/$endpoint');

    final token = await const FlutterSecureStorage().read(key: "access_token");
    final headers = {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };

    print("POST Request to: $url");
    print("Request Body: $body");

    try {
      final response = await http
          .post(
        url,
        headers: headers,
        body: jsonEncode(body),
      )
          .timeout(const Duration(seconds: 5));

      print("Response: ${response.statusCode}");
      print("Response Body: ${response.body}");

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return jsonDecode(response.body);
      } else {
        // Parse error response and throw specific messages
        final errorBody = jsonDecode(response.body);
        throw Exception(errorBody['detail'] ?? 'An unknown error occurred');
      }
    } catch (e) {
      print("POST Request Failed: $e");
      throw Exception('Failed to make POST request: $e');
    }
  }


  // Signup API integration
  Future<dynamic> signUp(String email, String password) async {
    return await post(
      'signup',
      {'email': email, 'password': password},
    );
  }

  // Login API integration
  Future<dynamic> login(String email, String password) async {
    try {
      final response = await post(
        'login',
        {'email': email, 'password': password},
      );

      // Extract and store the token securely
      if (response.containsKey('access_token')) {
        await const FlutterSecureStorage()
            .write(key: "access_token", value: response['access_token']);
        return {"success": true, "message": "Login successful"};
      } else {
        return {"success": false, "message": "Invalid response from server"};
      }
    } catch (e) {
      return {"success": false, "message": e.toString()};
    }
  }


  // Chat feature API integration
  Future<dynamic> chat(String message) async {
    return await post(
      'chat',
      {'message': message},
    );
  }

  // Dynamic chat function that configures which gpt you're talking to.
  Future<dynamic> d_chat(String message, String suffix) async {
    return await post (
      'chat/gpt',
      {'message': message, 'model': suffix},
    );
  }

  Future<void> googleLogin() async {
    final GoogleSignIn googleSignIn = GoogleSignIn(
      scopes: ['email'],
      serverClientId: '903732364114-a9d45n9fbroggcu23m7s3f7ti8ce7kf9.apps.googleusercontent.com',
    );
    final GoogleSignInAccount? account = await googleSignIn.signIn();

    if (account == null) {
      throw Exception('Google Sign In Failed');
    }

    final GoogleSignInAuthentication auth = await account.authentication;
    final token = auth.idToken;

    if (token == null) {
      throw Exception('Google Sign failed to provide token');
    }

    // Determine the platform
    String platform = Platform.isIOS ? 'ios' : 'android';

    // Send token and platform to the server
    final response = await post('google_login', {
      'token': token,
      'platform': platform,
    });

    if (response.containsKey('access_token')) {
      await const FlutterSecureStorage().write(
        key: "access_token",
        value: response['access_token'],
      );
    } else {
      throw Exception('Invalid response from server');
    }
  }
}
