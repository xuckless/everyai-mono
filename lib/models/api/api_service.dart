import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:google_sign_in/google_sign_in.dart';
import 'dart:io';

import '../utils/TokenManager.dart';
import 'auth_service.dart';

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
  /// Throws an [Exception] if the request fails or the server returns an error.
  ///
  /// - [endpoint]: The API endpoint to send the POST request to.
  /// - [body]: The JSON body of the POST request.
  /// - [headers]: Optional additional headers for the request.
  Future<dynamic> post(String endpoint, Map<String, dynamic> body,
      {Map<String, String>? headers}) async {
    String baseUrl = await _getAvailableBaseUrl();
    final url = Uri.parse('$baseUrl/$endpoint');

    // Merge default headers with custom headers
    final defaultHeaders = {
      'Content-Type': 'application/json',
    };
    final mergedHeaders = {...defaultHeaders, if (headers != null) ...headers};

    print("POST Request to: $url");
    print("Request Body: $body");

    try {
      final response = await http
          .post(
        url,
        headers: mergedHeaders,
        body: jsonEncode(body),
      )
          .timeout(const Duration(seconds: 15)); // Timeout after 15 seconds

      print("Response: ${response.statusCode}");
      print("Response Body: ${response.body}");

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return jsonDecode(response.body); // Return decoded JSON
      } else if (response.statusCode == 401) {
        throw Exception("Unauthorized");
      } else {
        final errorBody = jsonDecode(response.body);
        throw Exception(errorBody['detail'] ?? 'An unknown error occurred');
      }
    } catch (e) {
      print("POST Request Failed: $e");
      throw Exception('Failed to make POST request: $e');
    }
  }

  /// Sends a POST request without decoding the response (for raw data such as images).
  ///
  /// This method returns the raw [http.Response] without attempting to decode the body.
  ///
  /// - [endpoint]: The API endpoint to send the POST request to.
  /// - [body]: The JSON body of the request.
  /// - [headers]: Optional headers to include in the request.
  Future<http.Response> postRaw(String endpoint, Map<String, dynamic> body,
      {Map<String, String>? headers}) async {
    String baseUrl = await _getAvailableBaseUrl();
    final url = Uri.parse('$baseUrl/$endpoint');

    final defaultHeaders = {
      'Content-Type': 'application/json',
    };
    final mergedHeaders = {...defaultHeaders, if (headers != null) ...headers};

    print("POST Request to: $url");
    print("Request Body: $body");

    try {
      final response = await http
          .post(
        url,
        headers: mergedHeaders,
        body: jsonEncode(body),
      )
          .timeout(const Duration(seconds: 15));

      print("Response: ${response.statusCode}");
      return response;
    } catch (e) {
      print("POST Raw Request Failed: $e");
      throw Exception('Failed to make POST RAW request: $e');
    }
  }

  /// Refreshes the user's access token using a refresh token.
  ///
  /// Returns a map containing the new access token or an error message if the refresh fails.
  Future<dynamic> refreshToken(String refreshToken) async {
    try {
      final response = await post(
        'refresh_token',
        {'refresh_token': refreshToken},
      );

      if (response.containsKey('access_token')) {
        return {
          "success": true,
          "access_token": response['access_token'],
        };
      } else {
        return {"success": false, "message": "Invalid refresh token"};
      }
    } catch (e) {
      return {"success": false, "message": e.toString()};
    }
  }

  /// Sends an authenticated request to the server, refreshing the token if necessary.
  ///
  /// If the request fails due to an expired token, the method attempts to refresh
  /// the access token and retries the request.
  Future<dynamic> makeAuthenticatedRequest(
      String endpoint, Map<String, dynamic> body, AuthService authService) async {
    try {
      if (!TokenManager().isAccessTokenValid()) {
        final isRefreshed = await authService.refreshAccessToken();
        if (!isRefreshed) {
          throw Exception("Unable to refresh access token");
        }
      }
      final accessToken = TokenManager().accessToken;
      return await post(endpoint, body, headers: {
        'Authorization': 'Bearer $accessToken',
      });
    } catch (e) {
      throw Exception("API Request Failed: $e");
    }
  }
}