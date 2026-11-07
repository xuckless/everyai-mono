// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Who drives a live source now.
enum LiveDriver { agent, user }

/// Something the agent did on a live source, for the Preview's ghost cursor, ripples and caption. Points are in the
/// source's units.
@immutable
final class LiveActivity {
  const LiveActivity(this.kind, {this.x, this.y, this.caption = ''});

  /// `click`, `type`, `scroll`, `key`, `open`, `look`.
  final String kind;
  final double? x;
  final double? y;
  final String caption;
}

/// The driving lock of one live source (a session's browser, a simulator): the agent drives until the user takes
/// control (any input on the view does), and the agent's actions wait meanwhile, up to [hold]. Give back tells
/// the agent's next action what happened.
final class LiveControl extends ChangeNotifier {
  LiveControl({this.hold = const Duration(minutes: 2)});

  /// How long an agent action waits for the user to give control back before it gives up.
  final Duration hold;

  /// The live sources whose agent is waiting for the user to give control back, for the chat's reminder.
  static final ValueNotifier<List<LiveControl>> asking = ValueNotifier(const []);

  /// agentDriving → (take) userDriving → (an agent action) agentWaiting → (giveBack) agentDriving; a wait that
  /// runs out goes back to userDriving, and giveBack from userDriving goes straight to agentDriving.
  LiveControlPhase _phase = LiveControlPhase.agentDriving;
  LiveControlPhase get phase => _phase;

  LiveDriver get driver => _phase == LiveControlPhase.agentDriving ? LiveDriver.agent : LiveDriver.user;
  bool get userDriving => _phase != LiveControlPhase.agentDriving;

  /// Completes at Give back; set while the user drives.
  Completer<void>? _released;

  /// Agent actions waiting now (parallel calls wait together; the phase leaves agentWaiting when the last gives up).
  var _waiting = 0;

  /// Set at Give back; the agent's next action reads it once ([takeGiveBack]).
  bool _gaveBack = false;

  final _activity = StreamController<LiveActivity>.broadcast();

  /// The agent's actions as they happen (for the ghost cursor).
  Stream<LiveActivity> get activity => _activity.stream;

  void report(LiveActivity a) {
    if (!_activity.isClosed) _activity.add(a);
  }

  void _moveTo(LiveControlPhase next) {
    if (_phase == next) return;
    _phase = next;
    final others = [
      for (final c in asking.value)
        if (!identical(c, this)) c,
    ];
    asking.value = next == LiveControlPhase.agentWaiting ? [...others, this] : others;
    notifyListeners();
  }

  /// The user starts driving (their first input on the view, or Take control).
  void take() {
    if (_phase != LiveControlPhase.agentDriving) return;
    _released = Completer<void>();
    _moveTo(LiveControlPhase.userDriving);
  }

  /// The user hands control back to the agent (Give back, or Allow on the chat's reminder).
  void giveBack() {
    if (_phase == LiveControlPhase.agentDriving) return;
    _gaveBack = true;
    _released?.complete();
    _released = null;
    _moveTo(LiveControlPhase.agentDriving);
  }

  /// Waits until the agent may act: at once while it drives, else until Give back or [hold] passes. False when
  /// the user is still driving.
  Future<bool> agentTurn() async {
    final wait = _released;
    if (wait == null) return true;
    _waiting++;
    _moveTo(LiveControlPhase.agentWaiting);
    await wait.future.timeout(hold, onTimeout: () {});
    _waiting--;
    if (_phase == LiveControlPhase.agentWaiting && _waiting == 0) _moveTo(LiveControlPhase.userDriving);
    return _phase == LiveControlPhase.agentDriving;
  }

  /// Whether the user gave control back since the last call.
  bool takeGiveBack() {
    final v = _gaveBack;
    _gaveBack = false;
    return v;
  }

  @override
  void dispose() {
    _activity.close();
    _released?.complete();
    asking.value = [
      for (final c in asking.value)
        if (!identical(c, this)) c,
    ];
    super.dispose();
  }
}

/// Where a live source's driving lock is (see [LiveControl]).
enum LiveControlPhase {
  /// The agent drives.
  agentDriving,

  /// The user took control; the agent isn't asking for it.
  userDriving,

  /// The user drives and an agent action waits for them to give control back.
  agentWaiting,
}

/// What an agent's action gets while the user drives, after waiting [hold].
String userDrivingText(Duration hold) =>
    'The user is driving this view (they took control in the Preview) and did not give it back within '
    '${hold.inSeconds} s. Work on something else, or ask them to press Give back.';

/// The note an agent's first action after Give back starts with.
const gaveBackText =
    '[The user drove this view and gave it back. The page may have changed: look again (snapshot or screenshot) '
    'before acting on what you saw earlier.]';
