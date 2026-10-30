/// Authentication lifecycle:
///
/// ```text
///  Restoring ──token ok──► SignedIn ◄──────────┐
///      │                     │  signOut        │ success
///      └──none/invalid──► SignedOut ──submit──► Authenticating
///                            ▲                 │ failure
///                            └── (with error) ◄┘
///  Bypassed: DEV_SKIP_AUTH, no session at all (current default)
/// ```
sealed class AuthState {
  const AuthState();

  /// Whether the chat UI may be shown.
  bool get canUseApp => false;
}

final class Restoring extends AuthState {
  const Restoring();
}

final class SignedOut extends AuthState {
  const SignedOut({this.error});
  final String? error;
}

enum AuthMethod { password, signUp, google }

final class Authenticating extends AuthState {
  const Authenticating(this.method);
  final AuthMethod method;
}

final class SignedIn extends AuthState {
  const SignedIn();
  @override
  bool get canUseApp => true;
}

final class Bypassed extends AuthState {
  const Bypassed();
  @override
  bool get canUseApp => true;
}
