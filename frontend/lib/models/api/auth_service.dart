// ./lib/services/auth_service.dart

// import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../utils/TokenManager.dart';
import 'api_service.dart';

/// A service class responsible for managing authentication-related operations.
///
/// This includes user sign-up, login, token management, and Google authentication.
class AuthService {
  final ApiService _apiService;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  /// Initializes [AuthService] with an instance of [ApiService].
  AuthService(this._apiService);

  /// Registers a new user by sending their [name], [email], and [password] to the API.
  Future<dynamic> signUp(String name, String email, String password) async {
    return await _apiService.post(
      'signup',
      {'name': name, 'email': email, 'password': password},
    );
  }

  /// Authenticates a user by sending their [email] and [password] to the API.
  ///
  /// On successful authentication, stores tokens securely.
  Future<dynamic> login(String email, String password) async {
    try {
      final response = await _apiService.post(
        'login',
        {'email': email, 'password': password},
      );

      if (response.containsKey('access_token') && response.containsKey('refresh_token')) {
        // Store the access token in memory
        TokenManager().setAccessToken(response['access_token']);

        // Securely store the refresh token
        await _secureStorage.write(
          key: "refresh_token",
          value: response['refresh_token'],
        );

        // Save refresh token expiry (30 days from now)
        final refreshTokenExpiry = DateTime.now().add(Duration(days: 30));
        await _secureStorage.write(
          key: "refresh_token_expiry",
          value: refreshTokenExpiry.toIso8601String(),
        );

        return {
          "success": true,
          "message": "Login successful",
          "access_token": response['access_token'],
          "refresh_token": response['refresh_token'],
        };
      } else {
        return {"success": false, "message": "Invalid response from server"};
      }
    } catch (e) {
      return {"success": false, "message": e.toString()};
    }
  }

  /// Refreshes the access token using the refresh token stored securely.
  Future<bool> refreshAccessToken() async {
    final refreshToken = await _secureStorage.read(key: "refresh_token");

    if (refreshToken == null) {
      print("No refresh token found");
      return false;
    }

    try {
      final response = await _apiService.post(
        'refresh_token',
        {'refresh_token': refreshToken},
      );

      if (response.containsKey('access_token')) {
        // Update the access token in memory
        TokenManager().setAccessToken(
          response['access_token'],
          expiresIn: response['expires_in'], // Use the 'expires_in' from the response
        );
        return true;
      } else {
        print("Invalid refresh token response");
        return false;
      }
    } catch (e) {
      print("Error refreshing access token: $e");
      return false;
    }
  }

  /// Handles Google Sign-In authentication and token management.
  Future<void> googleLogin() async {
    final GoogleSignIn googleSignIn = GoogleSignIn(
      scopes: ['email'],
      serverClientId: '903732364114-a9d45n9fbroggcu23m7s3f7ti8ce7kf9.apps.googleusercontent.com',
    );

    final GoogleSignInAccount? account = await googleSignIn.signIn();
    if (account == null) {
      throw Exception('Google Sign In Failed');
    }

    final auth = await account.authentication;
    final token = auth.idToken;

    if (token == null) {
      throw Exception('Google Sign-In failed to provide a token');
    }

    final platform = Platform.isIOS ? 'ios' : 'android';

    final response = await _apiService.post('google_login', {
      'token': token,
      'platform': platform,
    });

    if (response.containsKey('access_token') && response.containsKey('refresh_token')) {
      TokenManager().setAccessToken(response['access_token']);

      await _secureStorage.write(
        key: "refresh_token",
        value: response['refresh_token'],
      );

      final refreshTokenExpiry = DateTime.now().add(Duration(days: 30));
      await _secureStorage.write(
        key: "refresh_token_expiry",
        value: refreshTokenExpiry.toIso8601String(),
      );
    } else {
      throw Exception('Invalid response from server');
    }
  }


}
