// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Processes are started and ended in `lib/core/process/` only (the supervisor: own process groups, the ledger,
/// verified kills). Files that still do it themselves are listed here until their phase moves them; the list only
/// shrinks: a file that no longer needs its entry fails the test too, so the entry goes.
const _allowed = <String>{
  'lib/core/local_backend/local_backend_io.dart',
  'lib/features/artifacts/script/svg_script_io.dart',
  'lib/features/code/domain/delivered_files.dart',
  'lib/features/code/drivers/acp/acp_files_io.dart',
  'lib/features/code/drivers/briefing/skill_export_io.dart',
  'lib/features/code/drivers/claude/claude_files_io.dart',
  'lib/features/code/drivers/detection/cli_scan.dart',
  'lib/features/code/drivers/detection/desktop_apps_io.dart',
  'lib/features/code/drivers/driver_process_io.dart',
  'lib/features/code/drivers/opencode/opencode_host_io.dart',
  'lib/features/code/drivers/registry_install/registry_install_io.dart',
  'lib/features/code/environments/environment_io_io.dart',
  'lib/features/code/git/git_service_io.dart',
  'lib/features/code/git/repo_check_io.dart',
  'lib/features/code/harness/everyai/app_tools_io.dart',
  'lib/features/code/harness/everyai/browser_io.dart',
  'lib/features/code/harness/everyai/everyai_harness_io.dart',
  'lib/features/code/harness/everyai/lsp_io.dart',
  'lib/features/code/harness/everyai/mcp_io.dart',
  'lib/features/code/harness/everyai/project_notes_io.dart',
  'lib/features/code/harness/everyai/prompt_io.dart',
  'lib/features/code/harness/everyai/script_io.dart',
  'lib/features/code/harness/everyai/shell_io.dart',
  'lib/features/code/harness/everyai/tools_io.dart',
  'lib/features/code/harness/everyai/window_ax_io.dart',
  'lib/features/code/harness/everyai/window_capture_io.dart',
  'lib/features/code/harness/session_processes_io.dart',
  'lib/features/code/host/host_screen_io.dart',
  'lib/features/code/live/adb_io.dart',
  'lib/features/code/live/android_device_io.dart',
  'lib/features/code/live/app_sources.dart',
  'lib/features/code/live/axe_install_io.dart',
  'lib/features/code/live/chrome_download_io.dart',
  'lib/features/code/live/desktop_helper_io.dart',
  'lib/features/code/live/desktop_window_io.dart',
  'lib/features/code/live/ios_simulator_io.dart',
  'lib/features/code/live/nested_display_io.dart',
  'lib/features/code/live/scrcpy_io.dart',
  'lib/features/code/live/webview_browser.dart',
  'lib/features/code/panes/file_tree_io.dart',
  'lib/features/code/panes/processes_io.dart',
  'lib/features/code/panes/pty_io.dart',
  'lib/features/code/resume/resume_files_io.dart',
  'lib/features/code/sample/sample_project_io.dart',
  'lib/features/code/session_notifications.dart',
  'lib/features/code/settings/settings_io.dart',
  'lib/features/code/shells/containers_io.dart',
  'lib/features/code/shells/pty_spawn_io.dart',
  'lib/features/code/ui/panes/browser_overlays.dart',
  'lib/features/code/workflows/workflow_bridge_io.dart',
  'lib/features/code/workflows/workflow_files_io.dart',
  'lib/features/local_models/data/local_system_io.dart',
  'lib/features/updates/data/install_io.dart',
};

/// A call or a tear-off (`run = Process.run`); comment lines don't count.
final _raw = RegExp(r'\b(Process\.(start|run|runSync|killPid)|Pty\.start)\b');

Set<String> rawSpawners() {
  final out = <String>{};
  for (final root in ['lib', 'packages']) {
    final d = Directory(root);
    if (!d.existsSync()) continue;
    for (final f in d.listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.startsWith('lib/core/process/')) continue;
      final code = f.readAsLinesSync().where((l) => !l.trimLeft().startsWith('//'));
      if (code.any(_raw.hasMatch)) out.add(path);
    }
  }
  return out;
}

void main() {
  test('processes are started and ended only through lib/core/process (apart from the files still listed)', () {
    final found = rawSpawners();
    final added = found.difference(_allowed).toList()..sort();
    final done = _allowed.difference(found).toList()..sort();
    expect(added, isEmpty, reason: 'Start and end processes through ProcessSupervisor (lib/core/process/).');
    expect(done, isEmpty, reason: 'These no longer start processes themselves: take them off the list.');
  });
}
