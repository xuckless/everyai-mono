/// Magic-link sign-in, one explicit state per step (owner, 2026-11-08: magic
/// link only, a click-through page plus a 6-digit code).
///
/// ```text
///  EnterEmail ──ask──► Requesting ──202──► Waiting ◄───────────┐
///      ▲                   │                 │  │ wrong code    │
///      │ ◄──refused/error──┘                 │  └──► Verifying ─┤
///      │                                     │         │ ok     │
///      │                       link approved │         ▼        │
///      │                       (poll)        └──►  (SignedIn)   │
///      │                                     │                  │
///      └──── another email ◄── Expired ◄─────┴─ expired/denied/dead
/// ```
///
/// Each flow has a [gen]: a poll or code answer that lands after the user
/// cancelled or started again carries an older one and is dropped.
sealed class MagicFlow {
  const MagicFlow(this.gen);
  final int gen;
}

/// Typing the address. [error] says why the last try didn't send.
final class EnterEmail extends MagicFlow {
  const EnterEmail(super.gen, {this.email = '', this.error});
  final String email;
  final String? error;
}

/// The ask is on its way to the server.
final class Requesting extends MagicFlow {
  const Requesting(super.gen, this.email);
  final String email;
}

/// The mail went out: the app polls for the link and takes the code.
final class Waiting extends MagicFlow {
  const Waiting(
    super.gen, {
    required this.email,
    required this.requestId,
    required this.secret,
    required this.sentAt,
    required this.expiresAt,
    this.codeError,
  });

  final String email;
  final String requestId;
  final String secret;
  final DateTime sentAt;
  final DateTime expiresAt;

  /// The last code was wrong ("That code isn't right. 3 tries left.").
  final String? codeError;

  Waiting withError(String? error) => Waiting(
    gen,
    email: email,
    requestId: requestId,
    secret: secret,
    sentAt: sentAt,
    expiresAt: expiresAt,
    codeError: error,
  );
}

/// A typed code is being checked; polling continues meanwhile.
final class Verifying extends MagicFlow {
  Verifying(this.waiting) : super(waiting.gen);
  final Waiting waiting;
}

/// The request can't be used any more (time ran out, Not me, too many
/// wrong codes). [reason] says which.
final class Expired extends MagicFlow {
  const Expired(super.gen, {required this.email, required this.reason});
  final String email;
  final String reason;
}
