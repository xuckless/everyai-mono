/// Every failure from the network layer, as a closed set the UI can switch over.
sealed class ApiError implements Exception {
  const ApiError(this.message);

  /// Human-readable, safe to show in the UI. Never contains tokens or request bodies.
  final String message;

  /// Whether retrying the same request might succeed.
  bool get retryable;

  @override
  String toString() => '$runtimeType: $message';
}

/// No route to the server (offline, DNS, refused, TLS).
final class NetworkError extends ApiError {
  const NetworkError(super.message);
  @override
  bool get retryable => true;
}

final class TimeoutError extends ApiError {
  const TimeoutError() : super('The server took too long to respond.');
  @override
  bool get retryable => true;
}

/// Access token missing, expired or rejected.
final class UnauthorizedError extends ApiError {
  const UnauthorizedError([super.message = 'Your session has expired. Sign in again.']);
  @override
  bool get retryable => false;
}

/// Non-2xx response that is not a 401.
final class HttpStatusError extends ApiError {
  const HttpStatusError(this.statusCode, super.message, {this.code});
  final int statusCode;

  /// Machine-readable reason, when the server sent one (`out_of_credits`).
  final String? code;

  /// A paid model with no plan quota or wallet balance left (HTTP 402).
  bool get outOfCredits => statusCode == 402;
  @override
  bool get retryable => statusCode >= 500 || statusCode == 429;
}

/// The server answered, but not in the shape the client expected.
final class ProtocolError extends ApiError {
  const ProtocolError(super.message);
  @override
  bool get retryable => false;
}

/// The caller cancelled the request (e.g. the stop button).
final class CancelledError extends ApiError {
  const CancelledError() : super('Cancelled.');
  @override
  bool get retryable => true;
}
