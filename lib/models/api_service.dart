import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class ApiService {
  // List of potential base URLs for the API
  final List<String> baseUrls = [
    'http://10.0.2.2:8000', // For Android emulator
    'http://192.168.1.100:8000', // Replace with your machine's IP for physical devices
    'http://127.0.0.1:8000', // For local development
    'http://localhost:8000', // Localhost fallback
  ];

  String? _cachedBaseUrl;

  ApiService();

  // Fetch the available base URL
  Future<String> _getAvailableBaseUrl() async {
    // Use cached base URL if still valid
    if (_cachedBaseUrl != null && await _isServerAvailable(_cachedBaseUrl!)) {
      return _cachedBaseUrl!;
    }

    // Iterate through the base URLs to find one that's reachable
    for (String url in baseUrls) {
      if (await _isServerAvailable(url)) {
        _cachedBaseUrl = url; // Cache successful base URL
        return url;
      }
    }

    // Throw an error if no base URLs are available
    throw Exception('No available base URLs');
  }

  // Check server availability for a given URL
  Future<bool> _isServerAvailable(String url) async {
    try {
      print("Checking URL: $url");
      final response = await http
          .get(Uri.parse('$url/ping'))
          .timeout(const Duration(seconds: 3));

      print("Response from $url: ${response.statusCode}");
      return response.statusCode == 200;
    } catch (e) {
      print("Error checking $url: $e");
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
}
