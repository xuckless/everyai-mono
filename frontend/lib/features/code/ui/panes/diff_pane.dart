import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../code_providers.dart';
import '../../domain/code_session.dart';
import '../../git/git_service.dart';

const _mono = TextStyle(fontFamily: 'SourceCodePro', fontSize: 12, height: 1.45);

/// The session's changes since it branched: files, hunks (each revertable)
/// and what to do with the work: commit, squash merge, push, PR, discard.
class DiffPane extends ConsumerStatefulWidget {
  const DiffPane({super.key, required this.session, required this.onClose});

  final CodeSessionInfo session;
  final VoidCallback onClose;

  @override
  ConsumerState<DiffPane> createState() => _DiffPaneState();
}

class _DiffPaneState extends ConsumerState<DiffPane> {
  final _collapsed = <String>{};
  bool _busy = false;

  CodeGit get _git => ref.read(codeGitProvider(widget.session.id).notifier);

  /// Runs [action], showing what failed instead of throwing.
  Future<void> _run(Future<String?> Function() action) async {
    setState(() => _busy = true);
    try {
      final done = await action();
      if (done != null && mounted) showAdaptiveToast(context, done);
    } on GitError catch (e) {
      if (mounted) showAdaptiveToast(context, e.message);
    } on Object catch (e) {
      if (mounted) showAdaptiveToast(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    final message = await showAdaptivePrompt(
      context,
      title: 'Commit message',
      confirmLabel: 'Commit',
      initialValue: widget.session.title,
    );
    if (message == null || message.trim().isEmpty) return;
    await _run(() async => await _git.commit(message.trim()) ? 'Committed' : 'Nothing to commit');
  }

  Future<void> _merge(SessionWorktree w) async {
    final message = await showAdaptivePrompt(
      context,
      title: 'Squash merge into ${w.baseBranch}',
      confirmLabel: 'Merge',
      initialValue: widget.session.title,
    );
    if (message == null || message.trim().isEmpty) return;
    await _run(() async {
      final sha = await _git.squashMerge(message.trim());
      return 'Merged into ${w.baseBranch} as ${sha.substring(0, 7)}';
    });
  }

  Future<void> _pr() async {
    final title = await showAdaptivePrompt(
      context,
      title: 'Pull request title',
      confirmLabel: 'Create',
      initialValue: widget.session.title,
    );
    if (title == null || title.trim().isEmpty) return;
    await _run(() async => 'Opened ${await _git.createPr(title: title.trim(), body: '')}');
  }

  Future<void> _discard() async {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Discard this session?',
      message: 'Deletes its worktree, branch and checkpoints. Work that was merged stays merged.',
      confirmLabel: 'Discard',
      destructive: true,
    );
    if (!ok) return;
    await _run(() async {
      await _git.discard();
      return null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final w = widget.session.worktree;
    final snapshot = ref.watch(codeGitProvider(widget.session.id));
    final git = snapshot.value;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surface,
        border: Border(left: BorderSide(color: theme.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Changes',
                        style: TextStyle(color: theme.text, fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      if (w != null)
                        Text(
                          '${w.branch} → ${w.baseBranch}'
                          '${git == null || git.ahead == 0 ? '' : ' · ${git.ahead} commit${git.ahead == 1 ? '' : 's'}'}'
                          '${git == null || git.behind == 0 ? '' : ' · ${w.baseBranch} moved ${git.behind} ahead'}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: theme.textMuted, fontSize: 12),
                        ),
                    ],
                  ),
                ),
                AdaptiveIconButton(icon: EveryIcon.retry, tooltip: 'Refresh', size: 16, onPressed: _git.refresh),
                AdaptiveIconButton(icon: EveryIcon.close, tooltip: 'Close', size: 16, onPressed: widget.onClose),
              ],
            ),
          ),
          Expanded(
            child: switch ((w, snapshot)) {
              (null, _) => _Empty(
                'This folder isn\'t a git repository, so the agent works in it directly and there is no diff to show.',
              ),
              (_, AsyncError(:final error)) => _Empty('$error'),
              (_, AsyncData(value: GitSnapshot(files: []))) => const _Empty(
                'No changes yet. Edits the agent makes in this session show up here.',
              ),
              (_, AsyncData(value: final g)) => ListView(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                children: [
                  for (final f in g.files)
                    _FileView(
                      file: f,
                      collapsed: _collapsed.contains(f.path),
                      onToggle: () => setState(
                        () => _collapsed.contains(f.path) ? _collapsed.remove(f.path) : _collapsed.add(f.path),
                      ),
                      onRevert: _busy ? null : (i) => _run(() async => _git.revertHunk(f, i).then((_) => null)),
                    ),
                ],
              ),
              _ => const Center(child: AdaptiveProgress()),
            },
          ),
          if (w != null)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: theme.border)),
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  AdaptiveButton(
                    label: 'Discard',
                    emphasis: ButtonEmphasis.destructive,
                    onPressed: _busy ? null : _discard,
                  ),
                  AdaptiveButton(label: 'Create PR', emphasis: ButtonEmphasis.secondary, onPressed: _busy ? null : _pr),
                  AdaptiveButton(
                    label: 'Commit',
                    emphasis: ButtonEmphasis.secondary,
                    onPressed: _busy ? null : _commit,
                  ),
                  AdaptiveButton(
                    label: 'Merge into ${w.baseBranch}',
                    busy: _busy,
                    onPressed: (git?.files.isEmpty ?? true) && (git?.ahead ?? 0) == 0 ? null : () => _merge(w),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.textMuted, fontSize: 13),
        ),
      ),
    );
  }
}

class _FileView extends StatelessWidget {
  const _FileView({required this.file, required this.collapsed, required this.onToggle, required this.onRevert});

  final FileDiff file;
  final bool collapsed;
  final VoidCallback onToggle;
  final void Function(int hunk)? onRevert;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final kindColor = switch (file.kind) {
      ChangeKind.added => theme.success,
      ChangeKind.deleted => theme.danger,
      _ => theme.warning,
    };
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  AdaptiveIcon(collapsed ? EveryIcon.chevronRight : EveryIcon.chevronDown, size: 13),
                  const SizedBox(width: 6),
                  Text(
                    file.kind.letter,
                    style: TextStyle(color: kindColor, fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      file.path,
                      overflow: TextOverflow.ellipsis,
                      style: _mono.copyWith(color: theme.text),
                    ),
                  ),
                  Text('+${file.added}', style: _mono.copyWith(color: theme.success)),
                  const SizedBox(width: 6),
                  Text('−${file.removed}', style: _mono.copyWith(color: theme.danger)),
                ],
              ),
            ),
          ),
          if (!collapsed && file.binary)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Text('Binary file', style: TextStyle(color: theme.textMuted, fontSize: 12)),
            ),
          if (!collapsed)
            for (final (i, hunk) in file.hunks.indexed)
              _HunkView(hunk: hunk, onRevert: onRevert == null ? null : () => onRevert!(i)),
        ],
      ),
    );
  }
}

class _HunkView extends StatelessWidget {
  const _HunkView({required this.hunk, required this.onRevert});

  final DiffHunk hunk;
  final VoidCallback? onRevert;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    var oldLine = hunk.oldStart, newLine = hunk.newStart;
    final rows = <Widget>[];
    for (final line in hunk.lines) {
      Color? bg;
      var fg = theme.textMuted;
      var number = '';
      switch (line.isEmpty ? ' ' : line[0]) {
        case '+':
          bg = theme.success.withValues(alpha: 0.12);
          fg = theme.text;
          number = '${newLine++}';
        case '-':
          bg = theme.danger.withValues(alpha: 0.12);
          fg = theme.text;
          number = '${oldLine++}';
        case r'\':
          break;
        default:
          number = '${newLine++}';
          oldLine++;
      }
      rows.add(
        Container(
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 34,
                child: Text(
                  number,
                  textAlign: TextAlign.right,
                  style: _mono.copyWith(color: theme.textMuted),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(line, softWrap: true, style: _mono.copyWith(color: fg)),
              ),
            ],
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.codeBackground,
        border: Border(top: BorderSide(color: theme.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
                  child: Text(
                    hunk.header,
                    overflow: TextOverflow.ellipsis,
                    style: _mono.copyWith(color: theme.textMuted),
                  ),
                ),
              ),
              if (onRevert != null)
                AdaptiveButton(label: 'Revert', emphasis: ButtonEmphasis.plain, onPressed: onRevert),
            ],
          ),
          ...rows,
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
