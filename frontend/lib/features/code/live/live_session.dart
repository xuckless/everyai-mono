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

  LiveDriver _driver = LiveDriver.agent;
  LiveDriver get driver => _driver;
  bool get userDriving => _driver == LiveDriver.user;

  Completer<void>? _released;

  /// Set at Give back; the agent's next action reads it once ([takeGiveBack]).
  bool _gaveBack = false;

  final _activity = StreamController<LiveActivity>.broadcast();

  /// The agent's actions as they happen (for the ghost cursor).
  Stream<LiveActivity> get activity => _activity.stream;

  void report(LiveActivity a) {
    if (!_activity.isClosed) _activity.add(a);
  }

  /// The user starts driving (their first input on the view, or Take control).
  void take() {
    if (_driver == LiveDriver.user) return;
    _driver = LiveDriver.user;
    _released = Completer<void>();
    notifyListeners();
  }

  /// The user hands control back to the agent.
  void giveBack() {
    if (_driver == LiveDriver.agent) return;
    _driver = LiveDriver.agent;
    _gaveBack = true;
    _released?.complete();
    _released = null;
    notifyListeners();
  }

  /// Waits until the agent may act: at once while it drives, else until Give back or [hold] passes. False when
  /// the user is still driving.
  Future<bool> agentTurn() async {
    final wait = _released;
    if (wait == null) return true;
    await wait.future.timeout(hold, onTimeout: () {});
    return _driver == LiveDriver.agent;
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
    super.dispose();
  }
}

/// What an agent's action gets while the user drives, after waiting [hold].
String userDrivingText(Duration hold) =>
    'The user is driving this view (they took control in the Preview) and did not give it back within '
    '${hold.inSeconds} s. Work on something else, or ask them to press Give back.';

/// The note an agent's first action after Give back starts with.
const gaveBackText =
    '[The user drove this view and gave it back. The page may have changed: look again (snapshot or screenshot) '
    'before acting on what you saw earlier.]';
