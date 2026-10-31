import 'dart:convert';

import 'message.dart';

/// The model offers to run the request again in another mode; the app shows
/// it as a button under the answer.
const suggestModeTool = 'suggest_mode';

/// The mode a `suggest_mode` call names (null when it names none the app
/// knows) and the reason shown on the button.
({ChatMode? mode, String reason}) suggestedMode(ToolCallPart part) {
  try {
    final args = jsonDecode(part.argumentsJson);
    if (args is! Map) return (mode: null, reason: '');
    final mode = ChatMode.values.where((m) => m.name == args['mode']).firstOrNull;
    final reason = args['reason'] is String ? (args['reason'] as String).trim() : '';
    return (mode: mode, reason: reason.length > 80 ? '${reason.substring(0, 79)}…' : reason);
  } on FormatException {
    return (mode: null, reason: '');
  }
}
