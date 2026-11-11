// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../harness/harness.dart' show NativeGrant, NativeRemember;
import 'permissions.dart' show ApprovalScope;

/// One way to allow on an outside lead's card: the scope the controller gets, and its button label.
typedef NativeAllowScope = ({ApprovalScope scope, String label});

/// The ways to allow an outside lead's call beyond "Just this once", from what its CLI can keep. Nothing is
/// stored in EveryAI's rules: an outside agent's own approvals decide its calls.
List<NativeAllowScope> nativeAllowScopes(NativeRemember remembers, String agent) => switch (remembers) {
  NativeRemember.onceOnly => const [],
  NativeRemember.session => const [(scope: ApprovalScope.session, label: 'Allow for this session')],
  NativeRemember.sessionOrSaved => [
    (scope: ApprovalScope.session, label: 'Allow for this session'),
    (scope: ApprovalScope.always, label: "Always allow (saved in $agent's settings)"),
  ],
  NativeRemember.agentAlways => [(scope: ApprovalScope.always, label: 'Always allow ($agent remembers it)')],
};

/// What [scope], picked on an outside lead's card, asks the CLI to keep; null: this call only (also for a scope the
/// CLI can't keep, which the card doesn't offer).
NativeGrant? nativeGrantOf(NativeRemember remembers, ApprovalScope scope) => switch (scope) {
  ApprovalScope.once || ApprovalScope.sessionAll => null,
  ApprovalScope.session => switch (remembers) {
    NativeRemember.session || NativeRemember.sessionOrSaved => NativeGrant.session,
    NativeRemember.onceOnly || NativeRemember.agentAlways => null,
  },
  ApprovalScope.always => switch (remembers) {
    NativeRemember.sessionOrSaved || NativeRemember.agentAlways => NativeGrant.always,
    NativeRemember.onceOnly || NativeRemember.session => null,
  },
};
