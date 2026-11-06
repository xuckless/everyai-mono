// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../code_providers.dart';
import 'containers.dart';
import 'shell_log.dart';
import 'shell_registry.dart';

/// The shells of Code session [sessionId] (its own and those carrying its billing tag, such as a fork's), oldest
/// first; updates when one starts, ends or gets input.
final sessionShellsProvider = StreamProvider.autoDispose.family<List<ShellEntry>, String>((ref, sessionId) async* {
  final registry = ShellRegistry.instance;
  Set<String> tags() {
    final info = ref.read(codeSessionsProvider).where((s) => s.id == sessionId).firstOrNull;
    return {sessionId, ?info?.billingTag};
  }

  List<ShellEntry> now() =>
      [for (final t in tags()) ...registry.of(t)]..sort((a, b) => a.startedAt.compareTo(b.startedAt));
  yield now();
  await for (final changed in registry.changes) {
    if (tags().contains(changed)) yield now();
  }
});

/// The terminal tab id that follows shell [key] in [owner]'s drawer.
String shellTabId(String owner, String key) => '$owner@shell:$key';

/// The shell key in a terminal tab id from [shellTabId], or null for a plain terminal tab.
String? shellKeyOf(String tabId) {
  final at = tabId.indexOf('@shell:');
  return at < 0 ? null : tabId.substring(at + 7);
}

/// The shell a terminal tab follows, by its registry key (any session).
ShellEntry? shellByKey(String key) {
  for (final s in ShellRegistry.instance.sessions) {
    if (ShellRegistry.instance.find(s, key) case final e?) return e;
  }
  return null;
}

/// A terminal tab following one shell: its log so far, then its output as it comes. Typing reaches the shell when
/// it runs in a terminal; one that ended (or runs on pipes) is read-only.
@immutable
final class ShellViewState {
  const ShellViewState({this.entry, this.loaded = false});
  final ShellEntry? entry;
  final bool loaded;
}

final shellViewProvider = NotifierProvider.family<ShellView, ShellViewState, String>(ShellView.new);

final class ShellView extends Notifier<ShellViewState> {
  ShellView(this.tabId);
  final String tabId;

  final terminal = Terminal(maxLines: 20000);
  StreamSubscription<({Uint8List bytes, int end})>? _sub;
  StreamSubscription<String>? _changes;
  var _started = false;

  @override
  ShellViewState build() {
    ref.onDispose(() {
      _sub?.cancel();
      _changes?.cancel();
    });
    final entry = shellByKey(shellKeyOf(tabId) ?? '');
    return ShellViewState(entry: entry);
  }

  /// Replays the log and follows the shell (once).
  void start() {
    if (_started) return;
    _started = true;
    final entry = state.entry;
    if (entry == null) {
      terminal.write('This shell is gone (EveryAI was restarted, or the session removed).\r\n');
      return;
    }
    // Read and subscribe in one go (the entry's output is delivered synchronously as it is logged), then skip any
    // chunk the log already held.
    final logged = entry.logPath == null ? entry.memory : readShellLogSync(entry.logPath!);
    final have = entry.logged;
    terminal.write(utf8.decode(logged, allowMalformed: true));
    _sub = entry.output.listen((c) {
      if (c.end <= have) return;
      final skip = c.bytes.length - (c.end - have);
      final fresh = skip > 0 ? Uint8List.sublistView(c.bytes, skip) : c.bytes;
      terminal.write(utf8.decode(fresh, allowMalformed: true));
    });
    if (entry.live case final live? when live.interactive) {
      terminal.onOutput = (data) => live.write(Uint8List.fromList(utf8.encode(data)));
      terminal.onResize = (w, h, pw, ph) => live.resize(h, w);
    }
    var ended = !entry.running;
    _changes = ShellRegistry.instance.changes.where((s) => s == entry.session).listen((_) {
      if (!entry.running && !ended) {
        ended = true;
        terminal
          ..onOutput = null
          ..write('\r\n\x1B[2m[Exited with code ${entry.exitCode}]\x1B[0m\r\n');
      }
      if (ref.mounted) state = ShellViewState(entry: entry, loaded: true);
    });
    if (ended) terminal.write('\r\n\x1B[2m[Exited with code ${entry.exitCode}]\x1B[0m\r\n');
    state = ShellViewState(entry: entry, loaded: true);
  }
}

/// The Docker/Podman containers of Code session [sessionId] (see `sessionContainersIn`), looked up every 5 s while
/// watched.
final sessionContainersProvider = StreamProvider.autoDispose.family<List<SessionContainer>, String>((
  ref,
  sessionId,
) async* {
  var alive = true;
  ref.onDispose(() => alive = false);
  while (alive) {
    final info = ref.read(codeSessionsProvider).where((s) => s.id == sessionId).firstOrNull;
    if (info == null || isDemoPath(info.workingDir)) {
      yield const [];
      return;
    }
    final registry = ShellRegistry.instance;
    yield await listSessionContainers(
      worktree: info.workingDir,
      hints: {...registry.hintsOf(sessionId), ...registry.hintsOf(info.billingTag)},
    );
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});
