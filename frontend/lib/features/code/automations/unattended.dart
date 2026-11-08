// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../domain/agent_mode.dart';
import '../resume/codex_sessions.dart' show codexHarness;

/// What still checks an unattended run (a webhook's or a schedule's) in [mode] on lead [harness]. On every lead
/// EveryAI's safety floor and the user's deny rules judge each call, except Codex in Auto: there Codex's own reviewer
/// answers them (`approvalsReviewer: auto_review`, see `codexPolicy`), and they never reach EveryAI.
String unattendedChecks(AgentMode mode, String harness) => mode == AgentMode.auto && harness == codexHarness
    ? "Codex's own reviewer decides each call in Auto: EveryAI's safety floor and your deny rules don't see them. "
          'Codex keeps to its workspace sandbox and asks only to step out of it.'
    : 'The safety floor and your deny rules still apply.';
