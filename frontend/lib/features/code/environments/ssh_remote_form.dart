// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import 'bridges.dart';

/// Letters, digits, dots, dashes and underscores, and one `@` between a user
/// and a host. No spaces, no shell characters, nothing that starts with `-`
/// (ssh would read it as an option).
final _targetPattern = RegExp(r'^[A-Za-z0-9._][A-Za-z0-9._-]*(@[A-Za-z0-9._][A-Za-z0-9._-]*)?$');

/// Whether [text] can be passed to ssh as a destination: an alias from
/// `~/.ssh/config` or `user@host`.
bool validSshTarget(String text) => _targetPattern.hasMatch(text.trim());

/// The remote [text] names (with the user's own [label]), or null when
/// [validSshTarget] refuses it.
SshRemote? parseSshTarget(String text, {String label = ''}) {
  final t = text.trim();
  if (!validSshTarget(t)) return null;
  final name = label.trim().isEmpty ? null : label.trim();
  final at = t.indexOf('@');
  final remote = at < 0
      ? SshRemote.alias(t, name: name)
      : SshRemote.host(user: t.substring(0, at), host: t.substring(at + 1), name: name);
  return remote.problem == null ? remote : null;
}

/// The small form for an ssh remote: an alias or user@host, an optional
/// label, and a line saying keys only. Save is off until the target is valid.
class SshRemoteForm extends StatefulWidget {
  const SshRemoteForm({super.key, required this.onSave, required this.onCancel});

  final ValueChanged<SshRemote> onSave;
  final VoidCallback onCancel;

  @override
  State<SshRemoteForm> createState() => _SshRemoteFormState();
}

class _SshRemoteFormState extends State<SshRemoteForm> {
  final _target = TextEditingController();
  final _label = TextEditingController();

  SshRemote? get _remote => parseSshTarget(_target.text, label: _label.text);

  @override
  void dispose() {
    _target.dispose();
    _label.dispose();
    super.dispose();
  }

  void _save() {
    if (_remote case final r?) widget.onSave(r);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final typed = _target.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add SSH remote', style: theme.type.callout.semibold.tint(theme.text)),
          const SizedBox(height: 8),
          AdaptiveTextField(
            key: const ValueKey('ssh-form.target'),
            controller: _target,
            autofocus: true,
            placeholder: 'Alias or user@host',
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          AdaptiveTextField(
            key: const ValueKey('ssh-form.label'),
            controller: _label,
            placeholder: 'Label (optional)',
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
          if (typed && _remote == null) ...[
            const SizedBox(height: 6),
            Text(
              'Use a name from your ssh config, or user@host. No spaces or special characters.',
              style: theme.type.caption.tint(theme.danger),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Signs in with your SSH key (ssh-agent or ~/.ssh/config). EveryAI never asks for or stores a password. '
            'Connect once from a terminal first, so the host is known.',
            style: theme.type.caption.tint(theme.textMuted),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              AdaptiveButton(label: 'Cancel', emphasis: ButtonEmphasis.plain, onPressed: widget.onCancel),
              const SizedBox(width: 8),
              AdaptiveButton(
                key: const ValueKey('ssh-form.save'),
                label: 'Add',
                onPressed: _remote == null ? null : _save,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
