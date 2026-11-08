import '../../core/config/billing_flag.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'auth_providers.dart';

/// Who is signed in (`GET /v1/me`).
final class Profile {
  const Profile({required this.id, required this.name, required this.email, this.plan = ''});

  static Profile? fromJson(Map<String, Object?> json) => switch (json) {
    {'id': final String id, 'name': final String name, 'email': final String email} => Profile(
      id: id,
      name: name.trim(),
      email: email.trim(),
      plan: json['plan'] is String ? json['plan']! as String : '',
    ),
    _ => null,
  };

  final String id;
  final String name;
  final String email;

  /// The plan id: free, pro or max (only meaningful with billing on).
  final String plan;

  /// "Pro plan"; empty while billing is parked.
  String get planLabel =>
      plan.isEmpty || !BillingFlag.enabled ? '' : '${plan[0].toUpperCase()}${plan.substring(1)} plan';

  /// The name to show: the name given at sign-up, else the email's local part.
  String get displayName => name.isNotEmpty ? name : email.split('@').first;
}

/// The signed-in user's profile; null while signed out or when the backend
/// can't be reached (the account row then shows placeholders). Refetched
/// whenever the sign-in state changes.
final profileProvider = FutureProvider<Profile?>((ref) async {
  if (!ref.watch(authProvider).hasAccount) return null;
  final authenticated = true;
  try {
    return Profile.fromJson(await ref.watch(apiClientProvider).getJson('v1/me', authenticated: authenticated));
  } on Object {
    return null;
  }
});
