// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Processes are started and ended in `lib/core/process/` only (the supervisor: own sessions, the ledger, verified
/// kills). Files that still do it themselves are listed here, with how many raw calls they hold, until their phase
/// moves them. The list only shrinks: a new raw call (in a listed file or a new one) fails, and so does a count
/// that went down (lower it, or drop the file).
const _allowed = <String, int>{
  'lib/core/local_backend/local_backend_io.dart': 2,
  'lib/features/artifacts/script/svg_script_io.dart': 1,
  'lib/features/code/domain/delivered_files.dart': 1,
  'lib/features/code/drivers/acp/acp_files_io.dart': 1,
  'lib/features/code/drivers/briefing/skill_export_io.dart': 1,
  'lib/features/code/drivers/claude/claude_files_io.dart': 1,
  'lib/features/code/drivers/detection/cli_scan.dart': 1,
  'lib/features/code/drivers/detection/desktop_apps_io.dart': 1,
  'lib/features/code/drivers/driver_process_io.dart': 4,
  'lib/features/code/drivers/opencode/opencode_host_io.dart': 1,
  'lib/features/code/drivers/registry_install/registry_install_io.dart': 1,
  'lib/features/code/environments/environment_io_io.dart': 1,
  'lib/features/code/git/git_service_io.dart': 8,
  'lib/features/code/git/repo_check_io.dart': 1,
  'lib/features/code/harness/everyai/app_tools_io.dart': 1,
  'lib/features/code/harness/everyai/browser_io.dart': 2,
  'lib/features/code/harness/everyai/everyai_harness_io.dart': 1,
  'lib/features/code/harness/everyai/lsp_io.dart': 3,
  'lib/features/code/harness/everyai/mcp_io.dart': 1,
  'lib/features/code/harness/everyai/project_notes_io.dart': 1,
  'lib/features/code/harness/everyai/prompt_io.dart': 1,
  'lib/features/code/harness/everyai/script_io.dart': 1,
  'lib/features/code/harness/everyai/shell_io.dart': 6,
  'lib/features/code/harness/everyai/tools_io.dart': 6,
  'lib/features/code/harness/everyai/window_ax_io.dart': 1,
  'lib/features/code/harness/everyai/window_capture_io.dart': 3,
  'lib/features/code/harness/session_processes_io.dart': 6,
  'lib/features/code/host/host_screen_io.dart': 1,
  'lib/features/code/live/adb_io.dart': 1,
  'lib/features/code/live/android_device_io.dart': 2,
  'lib/features/code/live/app_sources.dart': 1,
  'lib/features/code/live/axe_install_io.dart': 1,
  'lib/features/code/live/chrome_download_io.dart': 3,
  'lib/features/code/live/desktop_helper_io.dart': 2,
  'lib/features/code/live/desktop_window_io.dart': 2,
  'lib/features/code/live/ios_simulator_io.dart': 8,
  'lib/features/code/live/nested_display_io.dart': 1,
  'lib/features/code/live/scrcpy_io.dart': 1,
  'lib/features/code/live/webview_browser.dart': 2,
  'lib/features/code/panes/file_tree_io.dart': 1,
  'lib/features/code/panes/processes_io.dart': 4,
  'lib/features/code/panes/pty_io.dart': 2,
  'lib/features/code/resume/resume_files_io.dart': 1,
  'lib/features/code/sample/sample_project_io.dart': 1,
  'lib/features/code/session_notifications.dart': 2,
  'lib/features/code/settings/settings_io.dart': 1,
  'lib/features/code/shells/containers_io.dart': 3,
  'lib/features/code/shells/pty_spawn_io.dart': 1,
  'lib/features/code/ui/panes/browser_overlays.dart': 1,
  'lib/features/code/workflows/workflow_bridge_io.dart': 1,
  'lib/features/code/workflows/workflow_files_io.dart': 1,
  'lib/features/local_models/data/local_system_io.dart': 7,
  'lib/features/updates/data/install_io.dart': 2,
};

/// Calls and tear-offs (`run = Process.run`, `io.Process.start(`), across line breaks; `//` comments don't count.
final _raw = RegExp(r'\bProcess\s*\.\s*(?:start|run|runSync|killPid)\b|\bPty\s*\.\s*start\b');
final _comment = RegExp(r'(^|[ \t])//.*$', multiLine: true);

Map<String, int> rawSpawners() {
  final out = <String, int>{};
  for (final root in ['lib', 'packages']) {
    final d = Directory(root);
    if (!d.existsSync()) continue;
    for (final f in d.listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.startsWith('lib/core/process/')) continue;
      final n = _raw.allMatches(f.readAsStringSync().replaceAll(_comment, '')).length;
      if (n > 0) out[path] = n;
    }
  }
  return out;
}

void main() {
  test('processes are started and ended only through lib/core/process (apart from the counts still listed)', () {
    final found = rawSpawners();
    final more = [
      for (final e in found.entries)
        if (e.value > (_allowed[e.key] ?? 0)) '${e.key}: ${e.value} (allowed ${_allowed[e.key] ?? 0})',
    ]..sort();
    final fewer = [
      for (final e in _allowed.entries)
        if ((found[e.key] ?? 0) < e.value) '${e.key}: ${found[e.key] ?? 0} (listed ${e.value})',
    ]..sort();
    expect(more, isEmpty, reason: 'Start and end processes through ProcessSupervisor (lib/core/process/).');
    expect(fewer, isEmpty, reason: 'Fewer raw calls than listed: lower the count, or take the file off the list.');
  });

  test('the pattern sees calls, tear-offs, prefixed and split calls', () {
    const code = '''
final a = await Process.run('x', []);
KillRunner run = Process.run;
final b = io.Process.start('y', []);
final c = await Process
    .start('z', []);
final d = Pty.start('sh');
// Process.run in a comment
''';
    expect(_raw.allMatches(code.replaceAll(_comment, '')).length, 5);
  });
}
