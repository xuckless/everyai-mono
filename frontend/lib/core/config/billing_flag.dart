/// Credits, plans, wallet and top-ups: parked (owner, 2026-11-08). The code
/// stays, off unless the app is built with `--dart-define=BILLING_ENABLED=true`
/// against a backend with `BILLING_ENABLED=true`. With it off the app shows no
/// credits anywhere: models run on the user's own keys or local models.
abstract final class BillingFlag {
  /// Tests that cover the billing UI set this to true (and back in tearDown).
  static bool enabled = const bool.fromEnvironment('BILLING_ENABLED');
}
