// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

/// What a session runs besides the lead's own turn: its background forks and its running workflows (by name).
typedef SessionWork = ({int forks, List<String> workflows});

/// Whether [w] holds anything Stop all would stop that Stop doesn't.
bool hasSideWork(SessionWork w) => w.forks > 0 || w.workflows.isNotEmpty;

/// What Stop all stops, for its menu row: "the lead, 2 forks and Security review".
String stopAllScope(SessionWork w, {required bool leadBusy}) {
  final parts = [
    if (leadBusy) 'the lead',
    if (w.forks > 0) '${w.forks} ${w.forks == 1 ? 'fork' : 'forks'}',
    ...w.workflows,
  ];
  if (parts.length < 2) return parts.join();
  return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
}
