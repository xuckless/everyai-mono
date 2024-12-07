// ./lib/models/api_service.dart

import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:google_sign_in/google_sign_in.dart';
import 'dart:io';

/// A service class responsible for handling all API interactions.
///
/// The [ApiService] class manages HTTP requests to the backend server,
/// including user authentication, chat functionalities, and Google Sign-In.
/// It ensures secure storage of sensitive data like access tokens using
/// [FlutterSecureStorage](https://pub.dev/packages/flutter_secure_storage).
class ApiService {
  /// A list of potential base URLs for the API, accommodating different
  /// environments such as emulators, simulators, local development, and production.
  final List<String> baseUrls = [
    'http://10.0.2.2:8000', // For Android emulator
    'http://127.0.0.1:8000', // For iOS simulator
    'http://localhost:8000', // Fallback to localhost
    'https://everyai-backend-7k8g.onrender.com' // Production server
  ];

  /// Caches the successfully connected base URL to avoid repeated checks.
  String? _cachedBaseUrl;

  /// Creates an instance of [ApiService].
  ///
  /// Initializes the service without any specific configuration.
  ApiService();

  /// Retrieves an available base URL by checking each in the [baseUrls] list.
  ///
  /// Returns the first URL that responds successfully to a ping request.
  ///
  /// Throws an [Exception] if none of the URLs are available.
  Future<String> _getAvailableBaseUrl() async {
    // Return the cached base URL if it's already set
    if (_cachedBaseUrl != null) {
      return _cachedBaseUrl!;
    }

    // Iterate through each base URL to find an available server
    for (String url in baseUrls) {
      if (await _isServerAvailable(url)) {
        _cachedBaseUrl = url; // Cache the successful base URL
        return url;
      }
    }

    // Throw an exception if no servers are available
    throw Exception('No available base URLs');
  }

  /// Checks if the server at the given [url] is available by sending a ping request.
  ///
  /// Returns `true` if the server responds with a status code of 200, else `false`.
  ///
  /// - [url]: The base URL of the server to check.
  Future<bool> _isServerAvailable(String url) async {
    try {
      final response = await http
          .get(Uri.parse('$url/ping'))
          .timeout(const Duration(seconds: 3)); // Timeout after 3 seconds
      return response.statusCode == 200;
    } catch (_) {
      return false; // Return false if any exception occurs
    }
  }

  /// Sends a generalized POST request to the specified [endpoint] with the given [body].
  ///
  /// Automatically handles base URL selection, headers (including authorization),
  /// and error handling.
  ///
  /// Returns the decoded JSON response if the request is successful.
  ///
  /// - [endpoint]: The API endpoint to send the POST request to.
  /// - [body]: The JSON body of the POST request.
  ///
  /// Throws an [Exception] if the request fails or the server returns an error.
  Future<dynamic> post(String endpoint, Map<String, dynamic> body) async {
    // Retrieve an available base URL
    String baseUrl = await _getAvailableBaseUrl();
    final url = Uri.parse('$baseUrl/$endpoint');

    // Read the access token from secure storage, if available
    final token = await const FlutterSecureStorage().read(key: "access_token");
    final headers = {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token', // Include token if present
    };

    print("POST Request to: $url");
    print("Request Body: $body");

    try {
      // Send the POST request with headers and body
      final response = await http
          .post(
        url,
        headers: headers,
        body: jsonEncode(body),
      )
          .timeout(const Duration(seconds: 15)); // Timeout after 15 seconds

      print("Response: ${response.statusCode}");
      print("Response Body: ${response.body}");

      // Check if the response status code indicates success
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return jsonDecode(response.body); // Return the decoded JSON response
      } else {
        // Parse error response and throw specific messages
        final errorBody = jsonDecode(response.body);
        throw Exception(errorBody['detail'] ?? 'An unknown error occurred');
      }
    } catch (e) {
      print("POST Request Failed: $e");
      throw Exception('Failed to make POST request: $e'); // Rethrow as a generic exception
    }
  }

  /// Registers a new user by sending their [name], [email], and [password] to the API.
  ///
  /// - [name]: The full name of the user.
  /// - [email]: The user's email address.
  /// - [password]: The user's chosen password.
  ///
  /// Returns the API response as a decoded JSON object.
  ///
  /// Throws an [Exception] if the registration fails.
  Future<dynamic> signUp(String name, String email, String password) async {
    return await post(
      'signup', // API endpoint for user registration
      {'name': name, 'email': email, 'password': password}, // Request body
    );
  }

  /// Authenticates a user by sending their [email] and [password] to the API.
  ///
  /// Upon successful authentication, stores the received access token securely.
  ///
  /// - [email]: The user's email address.
  /// - [password]: The user's password.
  ///
  /// Returns a map indicating success status and a message.
  ///
  /// Example:
  /// ```dart
  /// {
  ///   "success": true,
  ///   "message": "Login successful"
  /// }
  /// ```
  Future<dynamic> login(String email, String password) async {
    try {
      final response = await post(
        'login', // API endpoint for user login
        {'email': email, 'password': password}, // Request body
      );

      // Extract and store the access token securely if present
      if (response.containsKey('access_token')) {
        await const FlutterSecureStorage().write(
          key: "access_token",
          value: response['access_token'],
        );
        return {"success": true, "message": "Login successful"};
      } else {
        return {"success": false, "message": "Invalid response from server"};
      }
    } catch (e) {
      return {"success": false, "message": e.toString()}; // Return error message
    }
  }

  /// Sends a chat message to the AI model.
  ///
  /// - [message]: The user's message to be sent.
  ///
  /// Returns the AI's response as a decoded JSON object.
  ///
  /// Throws an [Exception] if the request fails.
  Future<dynamic> chat(String message) async {
    return await post(
      'chat', // API endpoint for chat
      {'message': message}, // Request body
    );
  }

  /// Sends a chat message to a dynamically selected GPT model.
  ///
  /// - [message]: The user's message to be sent.
  /// - [suffix]: The identifier for the selected GPT model version.
  ///
  /// Returns the AI's response as a decoded JSON object.
  ///
  /// Throws an [Exception] if the request fails.
  Future<dynamic> d_chat(String message, String suffix) async {
    return await post(
      'chat/gpt', // API endpoint for GPT chat
      {'message': message, 'model': suffix}, // Request body
    );
  }

  /// Sends a chat message to the Gemini AI model.
  ///
  /// - [message]: The user's message to be sent.
  /// - [suffix]: The identifier for the selected Gemini model version.
  ///
  /// Returns the AI's response as a decoded JSON object.
  ///
  /// Throws an [Exception] if the request fails.
  Future<dynamic> g_chat(String message, String suffix) async {
    return await post(
      'chat/gemini', // API endpoint for Gemini chat
      {'message': message, 'model': suffix}, // Request body
    );
  }

  /// Sends a chat message to the LLaMA AI model.
  ///
  /// - [message]: The user's message to be sent.
  /// - [suffix]: The identifier for the selected LLaMA model version.
  ///
  /// Returns the AI's response as a decoded JSON object.
  ///
  /// Throws an [Exception] if the request fails.
  Future<dynamic> f_chat(String message, String suffix) async {
    return await post(
      'chat/llama', // API endpoint for LLaMA chat
      {'message': message, 'model': suffix}, // Request body
    );
  }


  Future<dynamic> xai_chat(String message, String suffix) async {
    return await post(
      'chat/xai',
      {'message': message, 'model': suffix},
    );
  }

  /// Handles Google Sign-In authentication.
  ///
  /// Initiates the Google Sign-In process, retrieves the authentication token,
  /// and sends it to the backend server for verification and user creation/login.
  ///
  /// Throws an [Exception] if the sign-in process fails at any step.
  Future<void> googleLogin() async {
    // Initialize GoogleSignIn with the required scopes and client ID
    final GoogleSignIn googleSignIn = GoogleSignIn(
      scopes: ['email'],
      serverClientId:
      '903732364114-a9d45n9fbroggcu23m7s3f7ti8ce7kf9.apps.googleusercontent.com',
    );

    // Attempt to sign in the user
    final GoogleSignInAccount? account = await googleSignIn.signIn();

    // If the user cancels the sign-in, throw an exception
    if (account == null) {
      throw Exception('Google Sign In Failed');
    }

    // Retrieve the authentication tokens
    final GoogleSignInAuthentication auth = await account.authentication;
    final token = auth.idToken;

    // If no token is retrieved, throw an exception
    if (token == null) {
      throw Exception('Google Sign failed to provide token');
    }

    // Determine the platform (iOS or Android) for backend processing
    String platform = Platform.isIOS ? 'ios' : 'android';

    // Send the token and platform information to the backend server
    final response = await post('google_login', {
      'token': token,
      'platform': platform,
    });

    // If the response contains an access token, store it securely
    if (response.containsKey('access_token')) {
      await const FlutterSecureStorage().write(
        key: "access_token",
        value: response['access_token'],
      );
    } else {
      // If no access token is received, throw an exception
      throw Exception('Invalid response from server');
    }
  }
}