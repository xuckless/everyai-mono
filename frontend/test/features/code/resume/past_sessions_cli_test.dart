// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:every_ai/features/code/resume/claude_sessions.dart';
import 'package:every_ai/features/code/resume/codex_sessions.dart';
import 'package:flutter_test/flutter_test.dart';

String _fixture(String name, String cwd, {String id = 'THREAD'}) =>
    File('test/fixtures/resume/$name').readAsStringSync().replaceAll('CWD', cwd).replaceAll('THREAD', id);

void main() {
  late Directory tmp;
  late String home;
  late String project;
  late String worktree;

  Future<String?> env(String name) async => name == 'HOME' ? home : null;
  Future<String> same(String p) async => p;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('resume_cli_');
    home = '${tmp.path}/home';
    project = '${tmp.path}/work/app';
    worktree = '${tmp.path}/wt/app-s1';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String slug(String p) => p.replaceAll(RegExp('[^A-Za-z0-9]'), '-');

  void claudeFile(String cwd, String id, String body) {
    File('$home/.claude/projects/${slug(cwd)}/$id.jsonl')
      ..createSync(recursive: true)
      ..writeAsStringSync(body);
  }

  group('Claude Code', () {
    test('lists the folder and its worktrees, newest first, with title, turns, model and branch', () async {
      claudeFile(project, 'old', _fixture('claude_session.jsonl', project));
      final newer = _fixture(
        'claude_session.jsonl',
        worktree,
      ).replaceAll('2026-11-01', '2026-11-03').replaceAll(RegExp(r'\{"type":"ai-title".*\}\n?'), '');
      claudeFile(worktree, 'new', newer);
      // A subagent thread under the session's folder and an empty file are not sessions.
      claudeFile(project, 'old/subagents/agent-1', _fixture('claude_session.jsonl', project));
      claudeFile(project, 'empty', '');
      // Another folder whose slug collides (`/work/app` and `/work-app`) is filtered by the records' cwd.
      claudeFile(project, 'other', _fixture('claude_session.jsonl', '${tmp.path}/work-app'));

      final list = await claudePastSessions(env: env, resolve: same).list(project, worktrees: [worktree]);
      expect(list.map((s) => s.nativeId), ['new', 'old']);
      final old = list[1];
      expect(old.harness, 'claude-code');
      expect(old.title, 'Counter with reset on the home page');
      expect(old.turns, 2); // the request and /review; tool results, meta and subagent lines don't count
      expect(old.model, 'claude-opus-5-5');
      expect(old.branch, 'feature/counter');
      expect(old.cwd, project);
      expect(old.lastActive, DateTime.utc(2026, 11, 1, 10, 2));
      expect(list[0].title, 'Add a counter to the home page please, with a reset button');
      expect(list[0].cwd, worktree);
    });
  });

  test("deleting removes Claude Code's session file and folder and Codex's rollout, nothing else", () async {
    claudeFile(project, 'gone', _fixture('claude_session.jsonl', project));
    claudeFile(project, 'gone/subagents/agent-1', _fixture('claude_session.jsonl', project));
    claudeFile(project, 'kept', _fixture('claude_session.jsonl', project));
    final claude = claudePastSessions(env: env, resolve: same);
    await claude.delete('gone', cwd: project);
    expect((await claude.list(project)).map((s) => s.nativeId), ['kept']);
    expect(Directory('$home/.claude/projects/${slug(project)}/gone').existsSync(), isFalse);

    for (final id in ['aaa', 'bbb']) {
      File('$home/.codex/sessions/2026/11/02/rollout-2026-11-02T09-00-00-$id.jsonl')
        ..createSync(recursive: true)
        ..writeAsStringSync(_fixture('codex_rollout.jsonl', project, id: id));
    }
    final codex = codexPastSessions(env: env, resolve: same);
    await codex.delete('aaa', cwd: project);
    expect((await codex.list(project)).map((s) => s.nativeId), ['bbb']);
  });
}
