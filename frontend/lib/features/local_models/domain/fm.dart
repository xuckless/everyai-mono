// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

/// Apple's Foundation Models CLI (`/usr/bin/fm`, macOS with Apple Intelligence). Every command but
/// `fm license --status` refuses (exit 69) until someone on the Mac ran `sudo fm license` and agreed to Apple's terms.
enum FmState {
  /// No `fm` here (not macOS, or an older macOS).
  missing,

  /// Installed, Apple's terms not agreed yet: the user runs `sudo fm license` in our terminal.
  needsLicence,

  /// This Mac can't run Apple Intelligence (Intel, or it's turned off / not supported here).
  unsupported,

  /// Ready to serve.
  ready,
}

@immutable
final class FmStatus {
  const FmStatus(this.state, {this.path, this.detail});
  final FmState state;
  final String? path;

  /// What `fm` said, for the row's subtitle.
  final String? detail;

  static const missing = FmStatus(FmState.missing);
}

/// The line typed (not run) into our terminal for the user to agree to Apple's terms.
const fmLicenceCommand = 'sudo fm license';

/// `fm license --status` (exit 0 either way): "You have already agreed to these terms." / "Agreed to license …"
/// or "Not agreed. Run 'sudo fm license' to review and agree.". Colour codes are stripped.
bool? parseFmLicence(String out) {
  final s = stripAnsi(out).toLowerCase();
  if (s.contains('not agreed') || s.contains('have not agreed')) return false;
  if (s.contains('already agreed') || s.contains('agreed to license')) return true;
  return null;
}

/// `fm models` output: unsupported when it says the device can't run Apple Intelligence or the system model is
/// unavailable.
bool parseFmUnsupported(String out) {
  final s = stripAnsi(out).toLowerCase();
  return s.contains('does not support apple intelligence') ||
      s.contains('apple intelligence is not enabled') ||
      s.contains('apple intelligence is turned off');
}

String stripAnsi(String s) => s.replaceAll(RegExp(r'\x1B\[[0-9;]*[A-Za-z]'), '');

/// Apple's `fm` command (macOS 27).
const fmExecutable = '/usr/bin/fm';
