//./lib/models/utils/TokenManager.dart

/// TokenManager is a singleton class that manages the access token in memory.
/// It tracks the token's value and expiration time, providing utility methods
/// for checking its validity and clearing it when necessary.
class TokenManager {
  // Singleton instance of TokenManager
  static final TokenManager _instance = TokenManager._internal();

  // Stores the access token
  String? _accessToken;

  // Stores the expiration time of the access token
  DateTime? _accessTokenExpiry;

  /// Factory constructor to return the singleton instance.
  factory TokenManager() {
    return _instance;
  }

  /// Private constructor for internal use to enforce singleton behavior.
  TokenManager._internal();

  /// Getter for the access token.
  ///
  /// Returns the current access token stored in memory.
  String? get accessToken => _accessToken;

  /// Setter for the access token and its expiration time.
  ///
  /// - [token]: The access token to store in memory.
  /// - [expiresIn]: The token's lifespan in seconds (optional). If provided,
  ///   it calculates and stores the expiration time of the token.
  void setAccessToken(String? token, {int? expiresIn}) {
    _accessToken = token; // Store the token in memory
    if (expiresIn != null) {
      // Calculate and store the expiration time based on the current time
      _accessTokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
    }
  }

  /// Checks if the access token is still valid.
  ///
  /// Returns:
  /// - `true` if the token has not expired.
  /// - `false` if the token is expired or no expiration time is set.
  bool isAccessTokenValid() {
    if (_accessTokenExpiry == null) return false; // No expiration time set
    return DateTime.now().isBefore(_accessTokenExpiry!); // Check if still valid
  }

  /// Clears the access token and its expiration time from memory.
  ///
  /// This is useful when the user logs out or the token is invalidated.
  void clearAccessToken() {
    _accessToken = null; // Clear the token
    _accessTokenExpiry = null; // Clear the expiration time
  }
}
