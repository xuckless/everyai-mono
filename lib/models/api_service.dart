import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  final List<String> baseUrls = [
    'http://10.0.2.2:8000',     // Android emulator
    'http://127.0.0.1:8000',    // iOS simulator or macOS app
    'http://localhost:8000',    // Web or other environments

  ];

  String? _cachedBaseUrl;

  ApiService();

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

  // Basic POST feature
  Future<dynamic> post(String endpoint, Map<String, dynamic> body) async {
    // Use the cached base URL
    String baseUrl = await _getAvailableBaseUrl();
    final url = Uri.parse('$baseUrl/$endpoint');

    try {
      final response = await http
          .post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        throw Exception('Request failed with status: ${response.statusCode}');
      }
    } catch (e) {
      // Invalidate the cached base URL if the request fails
      _cachedBaseUrl = null;

      // Retry with a new base URL if possible
      try {
        // Attempt to get a new available base URL
        String newBaseUrl = await _getAvailableBaseUrl();
        final newUrl = Uri.parse('$newBaseUrl/$endpoint');

        final response = await http
            .post(
          newUrl,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
            .timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          return jsonDecode(response.body);
        } else {
          throw Exception('Request failed with status: ${response.statusCode}');
        }
      } catch (e) {
        throw Exception('Failed to make POST request after retry: $e');
      }
    }
  }

  // POST request for Login page
  Future<dynamic> login(String email, String password) async {
    return await post(
      'login',
      {'email': email, 'password': password},
    );
  }

  Future<dynamic> signUp(String name, String email, String password) async {
    return await post(
      'sign-up',
      {'name': name, 'email': email, 'password': password},
    );
  }

  Future<dynamic> chat(String message) async {
    return await post(
      'chat',
      {'message': message},
    );
  }
}