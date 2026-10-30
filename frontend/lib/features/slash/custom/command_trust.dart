import 'custom_command.dart';

/// Which project commands the user has reviewed. A command file that came
/// with a cloned repository is a prompt someone else wrote, so it stays off
/// until trusted, and trust is bound to the file's digest: an edit turns it
/// off again. Global commands are the user's own and always run.
final class CommandTrust {
  const CommandTrust([this.trusted = const {}]);

  /// [CustomCommand.trustKey] → digest trusted.
  final Map<String, String> trusted;

  factory CommandTrust.fromJson(Object? json) => CommandTrust(<String, String>{
    for (final e in (json is Map ? json : const <String, String>{}).entries)
      if (e.key is String && e.value is String) e.key as String: e.value as String,
  });

  Map<String, String> toJson() => trusted;

  bool trustedNow(CustomCommand c) => c.isGlobal || (c.digest.isNotEmpty && trusted[c.trustKey] == c.digest);

  bool changedSinceTrusted(CustomCommand c) => !c.isGlobal && trusted.containsKey(c.trustKey) && !trustedNow(c);

  CommandTrust withTrust(CustomCommand c, bool on) =>
      CommandTrust(on ? {...trusted, c.trustKey: c.digest} : ({...trusted}..remove(c.trustKey)));

  /// Why a command is locked, for the list.
  String? lockedNote(CustomCommand c) {
    if (trustedNow(c)) return null;
    return changedSinceTrusted(c)
        ? 'Changed since you trusted it. Review it again to turn it on.'
        : 'Came with the project. Review it and trust it to turn it on.';
  }
}
