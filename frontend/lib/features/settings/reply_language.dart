import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/preferences.dart';

/// The languages offered for chat replies (the app itself stays English).
const replyLanguages = [
  'English',
  'Spanish',
  'French',
  'German',
  'Italian',
  'Portuguese',
  'Dutch',
  'Polish',
  'Turkish',
  'Russian',
  'Ukrainian',
  'Arabic',
  'Hebrew',
  'Persian',
  'Hindi',
  'Bengali',
  'Urdu',
  'Indonesian',
  'Vietnamese',
  'Thai',
  'Chinese (Simplified)',
  'Chinese (Traditional)',
  'Japanese',
  'Korean',
];

/// Which language chat replies and follow-up suggestions are written in:
/// [auto] (the language of the user's message) or a name from
/// [replyLanguages]. Preferences `chat.reply_language`.
final replyLanguageProvider = NotifierProvider<ReplyLanguage, String>(ReplyLanguage.new);

final class ReplyLanguage extends Notifier<String> {
  static const key = 'chat.reply_language';
  static const auto = 'auto';

  @override
  String build() {
    final v = ref.read(preferencesProvider)[key];
    return v == null || v.trim().isEmpty ? auto : v;
  }

  void set(String language) {
    final v = language.trim().isEmpty ? auto : language.trim();
    state = v;
    ref.read(preferencesProvider)[key] = v == auto ? null : v;
  }

  /// What the chat request sends: null for [auto].
  String? get wire => state == auto ? null : state;
}
