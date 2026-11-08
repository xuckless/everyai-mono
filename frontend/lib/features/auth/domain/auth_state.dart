import 'magic_flow.dart';

export 'magic_flow.dart';

/// The account lifecycle. An account is optional: the app works fully
/// signed out, and signing in only adds account features.
///
/// ```text
///  Restoring ──token ok──────────────────────► SignedIn
///      │                                        │  ▲
///      └──none/invalid──► SignedOut             │  │ redeemed
///                          │   ▲                │  │
///               startSignIn│   │cancel          │  │
///                          ▼   │                │  │
///                       SigningIn(MagicFlow) ───┼──┘
///                                               │ signOut
///                                               ▼
///                                           SigningOut ──► SignedOut
/// ```
///
/// Inside SigningIn the steps are a [MagicFlow] of their own.
sealed class AuthState {
  const AuthState();

  /// Whether account calls (`/v1/me`, keys, claims) can be made.
  bool get hasAccount => false;
}

final class Restoring extends AuthState {
  const Restoring();
}

final class SignedOut extends AuthState {
  const SignedOut({this.error});
  final String? error;
}

final class SigningIn extends AuthState {
  const SigningIn(this.flow);
  final MagicFlow flow;
}

final class SignedIn extends AuthState {
  const SignedIn();
  @override
  bool get hasAccount => true;
}

/// Revoking the refresh token and clearing local tokens; a second sign-out
/// meanwhile joins this one.
final class SigningOut extends AuthState {
  const SigningOut();
}
