import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Where a command shows: the chat composer, the Code composer, or both.
enum SlashScope {
  chat,
  code,
  both;

  bool covers(SlashScope surface) => this == both || this == surface;
}

/// The groups of the `/` menu, in display order.
enum SlashGroup {
  builtIn('Built-in'),
  custom('Custom'),
  skills('Skills'),
  connectors('Connectors');

  const SlashGroup(this.label);
  final String label;
}

/// What a command can do from the composer it was picked in. The host screen's
/// controls come in as callbacks; a command checks for the one it needs.
class SlashContext {
  SlashContext({
    required this.context,
    required this.surface,
    required this.setDraft,
    required this.send,
    this.chat,
    this.code,
  });

  final BuildContext context;

  /// Which composer ran the command.
  final SlashScope surface;

  /// Replaces the composer text (the caret goes to the end).
  final ValueChanged<String> setDraft;

  /// Sends [text] as a normal message from this composer.
  final ValueChanged<String> send;

  /// Chat composer controls, when [surface] is chat.
  final ChatSlashHost? chat;

  /// Code composer controls, when [surface] is code.
  final CodeSlashHost? code;
}

/// Chat composer controls a command may drive. Only [setMode] is always there;
/// a host that lacks a control leaves it null and the command says so.
class ChatSlashHost {
  const ChatSlashHost({
    required this.setMode,
    this.setModel,
    this.setEffort,
    this.sendWith,
    this.stage,
    this.newChat,
    this.retry,
    this.openMemory,
    this.exportChat,
    this.saveAsSkill,
  });

  /// Takes a `ChatMode` name: chat, search or research.
  final ValueChanged<String> setMode;

  /// Picks the model best matching a name; returns a message to show, or null.
  final String? Function(String query)? setModel;

  /// Sets the thinking effort by name (auto, low, medium, high, max); returns a message.
  final String? Function(String name)? setEffort;

  /// Sends [text] as a message, forcing [forceTool] on its first model call
  /// and giving the model [context] (skill instructions) with it.
  final void Function(String text, {String? forceTool, String? context})? sendWith;

  /// Holds [context] for the next message the user sends; [label] names it.
  final void Function(String label, String context)? stage;

  final VoidCallback? newChat;
  final VoidCallback? retry;
  final VoidCallback? openMemory;

  /// Saves the chat; [format] is md, pdf or docx (empty: Markdown).
  final ValueChanged<String>? exportChat;

  /// Summarizes the chat into a skill and saves it; the text is a hint for what it is for.
  final ValueChanged<String>? saveAsSkill;
}

/// Code composer controls a command may drive. Only [setMode] is always
/// there (the new-session composer has nothing else); an open session fills
/// in the rest.
class CodeSlashHost {
  const CodeSlashHost({
    required this.setMode,
    this.stop,
    this.build,
    this.setModel,
    this.setEffort,
    this.clear,
    this.compact,
    this.rewind,
    this.cost,
    this.btw,
  });

  /// Takes an `AgentMode` name: ask, autoEdit, plan or fullAuto.
  final ValueChanged<String> setMode;

  /// Null when the agent isn't working.
  final VoidCallback? stop;

  /// Leaves Plan mode and starts on the plan, or on the text given.
  final ValueChanged<String>? build;

  /// Switch the session's model or effort by name; the result is told to the user.
  final ValueChanged<String>? setModel;
  final ValueChanged<String>? setEffort;

  /// A fresh session in the same project; the text (if any) is its first message.
  final ValueChanged<String>? clear;

  /// Shortens the agent's context, keeping what the text asks for.
  final ValueChanged<String>? compact;

  /// Restores the files from before the latest turn(s); the text is a count.
  final ValueChanged<String>? rewind;
  final VoidCallback? cost;

  /// Asks a side question without disturbing the agent.
  final ValueChanged<String>? btw;
}

/// One entry of the `/` menu.
class SlashCommand {
  const SlashCommand({
    required this.name,
    required this.description,
    required this.run,
    this.argsHint,
    this.group = SlashGroup.builtIn,
    this.scope = SlashScope.both,
  });

  /// Without the slash: `search`, `plan`, a skill or custom command name.
  final String name;
  final String description;

  /// Shown after the name, e.g. `<question>`. A command with a hint is
  /// completed into the box on pick so the user can type the arguments.
  final String? argsHint;
  final SlashGroup group;
  final SlashScope scope;
  final FutureOr<void> Function(SlashContext context, String args) run;

  bool get takesArgs => argsHint != null && argsHint!.isNotEmpty;
}

/// The text being typed as a command name: the box starts with `/` and the
/// caret is still inside that first word. Null when the menu should stay shut.
String? slashQuery(TextEditingValue value) {
  final text = value.text;
  final sel = value.selection;
  if (!text.startsWith('/') || !sel.isValid || !sel.isCollapsed) return null;
  final caret = sel.baseOffset;
  if (caret < 1) return null;
  final word = text.substring(1, caret);
  if (word.contains(RegExp(r'\s'))) return null;
  // The caret has to be at the end of the word, not in its middle.
  if (caret < text.length && !RegExp(r'\s').hasMatch(text[caret])) return null;
  return word;
}

/// Commands for [surface] matching [query], grouped in [SlashGroup] order.
/// Inside a group: name prefix first, then name substring, then description.
List<SlashCommand> filterSlashCommands(Iterable<SlashCommand> commands, String query, SlashScope surface) {
  final q = query.toLowerCase();
  int? rank(SlashCommand c) {
    final name = c.name.toLowerCase();
    if (name.startsWith(q)) return 0;
    if (name.contains(q)) return 1;
    if (c.description.toLowerCase().contains(q)) return 2;
    return null;
  }

  final hits = [
    for (final c in commands)
      if (c.scope.covers(surface))
        if (rank(c) case final r?) (c, r),
  ];
  hits.sort((a, b) {
    final g = a.$1.group.index.compareTo(b.$1.group.index);
    if (g != 0) return g;
    final r = a.$2.compareTo(b.$2);
    if (r != 0) return r;
    return a.$1.name.compareTo(b.$1.name);
  });
  // A name shadows the same name later in the list (a custom command over a skill).
  final seen = <String>{};
  return [
    for (final (c, _) in hits)
      if (seen.add(c.name)) c,
  ];
}

/// A full command line typed into the box: `/name args`. Null when the text
/// isn't a known command for [surface], so it is sent as a normal message.
({SlashCommand command, String args})? parseSlashLine(
  String text,
  Iterable<SlashCommand> commands,
  SlashScope surface,
) {
  final m = RegExp(r'^/(\S+)(?:\s+([\s\S]*))?$').firstMatch(text.trim());
  if (m == null) return null;
  final name = m.group(1)!;
  for (final c in filterSlashCommands(commands, name, surface)) {
    if (c.name == name) return (command: c, args: (m.group(2) ?? '').trim());
  }
  return null;
}

/// The `/` menu's state for one composer: what's typed, the matches, the
/// highlighted row. The composer forwards text changes and key presses.
class SlashMenuController extends ChangeNotifier {
  SlashMenuController({required this.surface});

  final SlashScope surface;
  List<SlashCommand> _all = const [];
  List<SlashCommand> _matches = const [];
  int _highlight = 0;
  String? _query;
  String? _dismissed;

  List<SlashCommand> get matches => _matches;
  int get highlight => _highlight;
  bool get isOpen => _matches.isNotEmpty;
  List<SlashCommand> get commands => _all;

  /// Recomputes the menu after the text or the command list changed.
  void update(TextEditingValue value, List<SlashCommand> commands) {
    _all = commands;
    final query = slashQuery(value);
    // Esc keeps it shut until the word changes.
    if (query != _dismissed) _dismissed = null;
    final matches = query == null || query == _dismissed
        ? const <SlashCommand>[]
        : filterSlashCommands(commands, query, surface);
    final queryChanged = query != _query;
    _query = query;
    if (queryChanged || _highlight >= matches.length) _highlight = 0;
    if (!_sameList(matches, _matches) || queryChanged) {
      _matches = matches;
      notifyListeners();
    }
  }

  void move(int by) {
    if (_matches.isEmpty) return;
    _highlight = (_highlight + by) % _matches.length;
    notifyListeners();
  }

  void hover(int index) {
    if (index == _highlight || index < 0 || index >= _matches.length) return;
    _highlight = index;
    notifyListeners();
  }

  void dismiss() {
    _dismissed = _query;
    _matches = const [];
    notifyListeners();
  }

  /// Handles ↑/↓/Tab/Enter/Esc while the menu is open. [onPick] gets the
  /// highlighted command. Returns null when the key isn't the menu's.
  KeyEventResult? handleKey(KeyEvent event, ValueChanged<SlashCommand> onPick) {
    if (!isOpen || event is KeyUpEvent) return null;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      move(1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      move(-1);
    } else if (event is KeyRepeatEvent) {
      return null;
    } else if (key == LogicalKeyboardKey.tab ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (HardwareKeyboard.instance.isShiftPressed && key != LogicalKeyboardKey.tab) return null;
      onPick(_matches[_highlight]);
    } else if (key == LogicalKeyboardKey.escape) {
      dismiss();
    } else {
      return null;
    }
    return KeyEventResult.handled;
  }

  static bool _sameList(List<SlashCommand> a, List<SlashCommand> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }
}

/// Runs a picked or typed command from a composer. Commands with an args hint
/// and no args yet are completed into the box instead (`/name `), so the user
/// types the arguments and presses Enter again.
Future<void> runSlash(SlashCommand command, String args, SlashContext context, {bool complete = true}) async {
  if (complete && command.takesArgs && args.isEmpty) {
    context.setDraft('/${command.name} ');
    return;
  }
  context.setDraft('');
  await command.run(context, args);
}
