import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/net/api_error.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../remote/data/remote_api.dart' show HookInfo;
import '../../../remote/remote_providers.dart' show remoteApiProvider, remoteHostingProvider;
import '../../code_providers.dart' show codeProjectsProvider;
import '../../domain/agent_mode.dart';
import '../../domain/code_session.dart' show everyaiHarnessName;
import '../../drivers/driver_registry.dart' show driverRegistryProvider;
import '../webhook.dart';
import '../webhook_providers.dart';
import 'scheduled_tasks_body.dart' show whenLabel;

String _message(Object e) => e is ApiError ? e.message : '$e';

/// How another sender signs a delivery, for the secret card (backend-exp README "Webhooks").
String signingRecipe(String url) =>
    'body=\'{"task":"triage"}\'; ts=\$(date +%s)\n'
    'sig=\$(printf \'%s.%s\' "\$ts" "\$body" | openssl dgst -sha256 -hmac "\$secret" -hex | sed \'s/^.* //\')\n'
    'curl -X POST \'$url\' -H \'Content-Type: application/json\' \\\n'
    '  -H "X-EveryAI-Timestamp: \$ts" -H "X-EveryAI-Signature: sha256=\$sig" --data "\$body"';

/// The Webhooks part of Settings → Code → Scheduled tasks: URLs that start a Code session on this computer when a
/// service (GitHub, CI, a script) posts to them. Deliveries come through the relay, so hosting has to be on.
class WebhooksPart extends ConsumerStatefulWidget {
  const WebhooksPart({super.key});

  @override
  ConsumerState<WebhooksPart> createState() => _WebhooksPartState();
}

class _WebhooksPartState extends ConsumerState<WebhooksPart> {
  /// The account's hooks on the backend; null until loaded (or when it can't be reached).
  List<HookInfo>? _server;

  /// The automation in the form: a new one (hook id '') or an existing one.
  WebhookAutomation? _editing;

  /// A hook just created: its secret is shown this once.
  ({String name, String url, String secret})? _revealed;
  String? _error;
  bool _busy = false;
  bool _enabling = false;

  /// Bumped by each refresh and each local change to the list: an older refresh that answers late is dropped, so it
  /// can't bring back a hook deleted meanwhile.
  int _listGen = 0;

  @override
  void initState() {
    super.initState();
    // With hosting off nothing can arrive, and there is no host to list hooks for yet.
    if (ref.read(remoteHostingProvider).enabled) _refresh();
  }

  Future<void> _refresh() async {
    final gen = ++_listGen;
    try {
      final hooks = await ref.read(remoteApiProvider).hooks();
      if (mounted && gen == _listGen) setState(() => _server = hooks);
    } on Object {
      // Offline or signed out: the local list still shows.
    }
  }

  Future<void> _create(WebhookAutomation draft) async {
    final host = ref.read(remoteHostingProvider).host;
    if (host == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final made = await ref
          .read(remoteApiProvider)
          .createHook(name: draft.name, hostId: host.id, hostToken: host.token);
      ref
          .read(webhookAutomationsProvider.notifier)
          .put(
            WebhookAutomation(
              hookId: made.hook.id,
              name: draft.name,
              url: made.hook.url,
              projectId: draft.projectId,
              prompt: draft.prompt,
              harness: draft.harness,
              model: draft.model,
              mode: draft.mode,
              unattendedConfirmed: draft.unattendedConfirmed,
              event: draft.event,
            ),
          );
      if (!mounted) return;
      setState(() {
        _editing = null;
        _revealed = (name: draft.name, url: made.hook.url, secret: made.secret);
      });
      await _refresh();
    } on Object catch (e) {
      if (mounted) setState(() => _error = "Couldn't create the webhook: ${_message(e)}");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(String hookId, String name) async {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Delete "$name"?',
      message: 'Its URL stops working at once, and deliveries waiting for this computer are dropped.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _error = null);
    try {
      // Without a host here its hooks went with it on the server; only its own token deletes one.
      final host = ref.read(remoteHostingProvider).host;
      if (host != null) await ref.read(remoteApiProvider).deleteHook(hookId, hostToken: host.token);
    } on Object catch (e) {
      // Already gone on the server is fine; otherwise the local entry stays so it can be tried again.
      if (e is! HttpStatusError || e.statusCode != 404) {
        if (mounted) setState(() => _error = "Couldn't delete the webhook: ${_message(e)}");
        return;
      }
    }
    ref.read(webhookAutomationsProvider.notifier).remove(hookId);
    _listGen++;
    if (mounted) setState(() => _server = _server?.where((h) => h.id != hookId).toList());
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final hosting = ref.watch(remoteHostingProvider);
    ref.listen(remoteHostingProvider.select((s) => s.enabled), (was, on) {
      if (on && was != true) _refresh();
    });
    final automations = ref.watch(webhookAutomationsProvider);
    final projects = ref.watch(codeProjectsProvider);
    final server = {for (final h in _server ?? const <HookInfo>[]) h.id: h};
    final editing = _editing;
    final revealed = _revealed;

    Widget tile(WebhookAutomation a) {
      final project = projects.where((p) => p.id == a.projectId).firstOrNull?.name ?? 'Project gone';
      final pending = server[a.hookId]?.pending ?? 0;
      final status =
          a.lastError ??
          (a.lastDeliveryAt == null ? 'No deliveries yet' : 'Last delivery ${whenLabel(a.lastDeliveryAt!)}');
      return AdaptiveListTile(
        title: Text(a.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$project · ${a.effectiveMode.label}${a.event.isEmpty ? '' : ' · on ${a.event}'}'
              '${pending > 0 ? ' · $pending waiting' : ''}',
              style: theme.type.caption.tint(theme.textMuted),
            ),
            Text(status, style: theme.type.caption.tint(a.lastError != null ? theme.danger : theme.textMuted)),
          ],
        ),
        onTap: () => setState(() => _editing = a),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AdaptiveSwitch(
              value: a.enabled,
              onChanged: (on) =>
                  ref.read(webhookAutomationsProvider.notifier).patch(a.hookId, (x) => x.copyWith(enabled: on)),
            ),
            AdaptiveMenuButton(
              tooltip: 'More',
              actions: [
                MenuAction(
                  label: 'Copy URL',
                  icon: EveryIcon.copy,
                  onSelected: () => Clipboard.setData(ClipboardData(text: a.url)),
                ),
                MenuAction(label: 'Edit', icon: EveryIcon.edit, onSelected: () => setState(() => _editing = a)),
                MenuAction(
                  label: 'Delete',
                  icon: EveryIcon.delete,
                  destructive: true,
                  onSelected: () => _delete(a.hookId, a.name),
                ),
              ],
              child: const Padding(padding: EdgeInsets.all(6), child: AdaptiveIcon(EveryIcon.more, size: 16)),
            ),
          ],
        ),
      );
    }

    final elsewhere = [
      for (final h in server.values)
        if (!automations.any((a) => a.hookId == h.id)) h,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 24, 4, 4),
          child: Text('Webhooks', style: theme.type.headline),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Text(
            'A webhook URL starts a Code session on this computer when a service (GitHub, CI, a script) posts to it. '
            'Payloads pass through the EveryAI server and reach the agent as data, never as instructions. Sessions '
            'run in Auto-edit unless you pick otherwise, so commands still wait for you.',
            style: theme.type.callout.tint(theme.textMuted),
          ),
        ),
        if (!hosting.enabled) ...[
          AdaptiveListTile(
            title: const Text('Turn on remote hosting to receive webhooks'),
            subtitle: Text(
              'Deliveries reach this computer through the same connection your other devices use.',
              style: theme.type.caption.tint(theme.textMuted),
            ),
            trailing: AdaptiveButton(
              label: 'Turn on hosting',
              busy: _enabling,
              onPressed: _enabling
                  ? null
                  : () async {
                      setState(() {
                        _enabling = true;
                        _error = null;
                      });
                      try {
                        await ref.read(remoteHostingProvider.notifier).enable();
                      } on Object catch (e) {
                        if (mounted) setState(() => _error = "Couldn't turn hosting on: ${_message(e)}");
                      } finally {
                        if (mounted) setState(() => _enabling = false);
                      }
                    },
            ),
          ),
        ] else ...[
          if (revealed != null) _SecretCard(revealed: revealed, onDone: () => setState(() => _revealed = null)),
          if (automations.isEmpty && elsewhere.isEmpty && editing == null)
            AdaptiveListTile(title: Text('No webhooks yet', style: theme.type.body.tint(theme.textMuted))),
          for (final a in automations)
            if (editing?.hookId == a.hookId)
              _WebhookForm(
                key: ValueKey('hook-${a.hookId}'),
                initial: a,
                busy: _busy,
                onCancel: () => setState(() => _editing = null),
                onSave: (x) {
                  ref.read(webhookAutomationsProvider.notifier).put(x);
                  setState(() => _editing = null);
                },
              )
            else
              tile(a),
          for (final h in elsewhere)
            AdaptiveListTile(
              title: Text(h.name),
              subtitle: Text(
                'Made on another computer or before this one was set up again; it starts nothing here.',
                style: theme.type.caption.tint(theme.textMuted),
              ),
              trailing: AdaptiveButton(
                label: 'Delete',
                emphasis: ButtonEmphasis.secondary,
                onPressed: () => _delete(h.id, h.name),
              ),
            ),
          if (editing != null && editing.hookId.isEmpty)
            _WebhookForm(
              key: const ValueKey('hook-new'),
              initial: editing,
              busy: _busy,
              onCancel: () => setState(() => _editing = null),
              onSave: _create,
            ),
          if (editing == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: AdaptiveButton(
                  label: 'Add webhook',
                  emphasis: ButtonEmphasis.secondary,
                  icon: const AdaptiveIcon(EveryIcon.add, size: 14),
                  onPressed: projects.isEmpty
                      ? null
                      : () => setState(
                          () => _editing = WebhookAutomation(
                            hookId: '',
                            name: '',
                            url: '',
                            projectId: projects.first.id,
                            prompt: '',
                          ),
                        ),
                ),
              ),
            ),
        ],
        if (_error case final e?)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(e, style: theme.type.caption.tint(theme.danger)),
          ),
      ],
    );
  }
}

/// The URL and secret of a hook just created, shown once, with how to use them.
class _SecretCard extends StatelessWidget {
  const _SecretCard({required this.revealed, required this.onDone});

  final ({String name, String url, String secret}) revealed;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          SizedBox(width: 60, child: Text(label, style: theme.type.caption.tint(theme.textMuted))),
          Expanded(child: Text(value, style: theme.type.footnote.mono)),
          AdaptiveButton(
            label: 'Copy',
            emphasis: ButtonEmphasis.secondary,
            onPressed: () => Clipboard.setData(ClipboardData(text: value)),
          ),
        ],
      ),
    );
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.accent),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('"${revealed.name}" is ready', style: theme.type.body.semibold),
          Text(
            "Copy the secret now: it isn't shown again. To change it, delete the webhook and add a new one.",
            style: theme.type.caption.tint(theme.warning),
          ),
          row('URL', revealed.url),
          row('Secret', revealed.secret),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              "GitHub: in the repository's Settings → Webhooks, paste the URL as the Payload URL and the secret as "
              'the Secret, with content type application/json.\nOther senders sign each POST like this:',
              style: theme.type.caption.tint(theme.textMuted),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(signingRecipe(revealed.url), style: theme.type.micro.mono),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: AdaptiveButton(label: 'Done', onPressed: onDone),
            ),
          ),
        ],
      ),
    );
  }
}

class _WebhookForm extends ConsumerStatefulWidget {
  const _WebhookForm({
    super.key,
    required this.initial,
    required this.busy,
    required this.onCancel,
    required this.onSave,
  });

  final WebhookAutomation initial;
  final bool busy;
  final VoidCallback onCancel;
  final ValueChanged<WebhookAutomation> onSave;

  @override
  ConsumerState<_WebhookForm> createState() => _WebhookFormState();
}

class _WebhookFormState extends ConsumerState<_WebhookForm> {
  late final _name = TextEditingController(text: widget.initial.name);
  late final _prompt = TextEditingController(text: widget.initial.prompt);
  late final _model = TextEditingController(text: widget.initial.model);
  late final _event = TextEditingController(text: widget.initial.event);
  late String _projectId = widget.initial.projectId;
  late String _harness = widget.initial.harness;
  late AgentMode _mode = widget.initial.effectiveMode;
  late bool _confirmed = widget.initial.unattendedConfirmed;

  @override
  void dispose() {
    for (final c in [_name, _prompt, _model, _event]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickMode(AgentMode m) async {
    if (m == AgentMode.fullAuto && !_confirmed) {
      final ok = await showAdaptiveConfirm(
        context,
        title: 'Run webhook sessions in Full auto?',
        message:
            'An outside service starts these sessions and nobody watches them. Full auto runs commands and edits '
            'without asking, and what the sender writes could try to steer the agent. The safety floor and your deny '
            'rules still apply.',
        confirmLabel: 'Use Full auto',
      );
      if (!ok) return;
      _confirmed = true;
    }
    if (mounted) setState(() => _mode = m);
  }

  bool get _complete => _name.text.trim().isNotEmpty && _prompt.text.trim().isNotEmpty;

  void _submit() {
    if (!_complete) return;
    widget.onSave(
      widget.initial.copyWith(
        name: _name.text.trim(),
        projectId: _projectId,
        prompt: _prompt.text.trim(),
        harness: _harness,
        model: _model.text.trim(),
        mode: _mode,
        unattendedConfirmed: _mode == AgentMode.fullAuto && _confirmed,
        event: _event.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final projects = ref.watch(codeProjectsProvider);
    final drivers = ref.watch(driverRegistryProvider).listed.toList();
    final lead = drivers.where((d) => d.info.id == _harness).firstOrNull?.info.label ?? _harness;
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Text(text, style: theme.type.caption.tint(theme.textMuted)),
    );
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdaptiveTextField(
            controller: _name,
            placeholder: 'Name (New issues, Failed CI, …)',
            onChanged: (_) => setState(() {}),
          ),
          label('Project, lead and mode'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AdaptiveMenuButton(
                actions: [
                  for (final p in projects)
                    MenuAction(
                      label: p.name,
                      checked: p.id == _projectId,
                      onSelected: () => setState(() => _projectId = p.id),
                    ),
                ],
                child: MenuTrigger(projects.where((p) => p.id == _projectId).firstOrNull?.name ?? 'Pick a project'),
              ),
              AdaptiveMenuButton(
                actions: [
                  for (final d in drivers)
                    MenuAction(
                      label: d.info.label,
                      checked: d.info.id == _harness,
                      onSelected: () => setState(() => _harness = d.info.id),
                    ),
                ],
                child: MenuTrigger(lead),
              ),
              AdaptiveMenuButton(
                actions: [
                  for (final m in AgentMode.values.where((m) => m != AgentMode.bypass))
                    MenuAction(label: m.label, checked: m == _mode, onSelected: () => _pickMode(m)),
                ],
                child: MenuTrigger(_mode.label),
              ),
            ],
          ),
          const SizedBox(height: 8),
          AdaptiveTextField(
            controller: _model,
            placeholder: _harness == everyaiHarnessName
                ? 'Model id (empty: the one picked in Code)'
                : 'Model (empty: the one picked for this lead)',
          ),
          const SizedBox(height: 8),
          AdaptiveTextField(
            controller: _event,
            placeholder: 'Only on this event, e.g. issues or push (empty: every one)',
          ),
          label('What it should do'),
          AdaptiveTextField(
            controller: _prompt,
            minLines: 3,
            maxLines: 8,
            placeholder: 'The first message. {{body}} is the payload, {{json.issue.title}} one field of it.',
            onChanged: (_) => setState(() {}),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AdaptiveButton(label: 'Cancel', emphasis: ButtonEmphasis.secondary, onPressed: widget.onCancel),
                const SizedBox(width: 8),
                AdaptiveButton(
                  label: widget.initial.hookId.isEmpty ? 'Create' : 'Save',
                  onPressed: _complete && !widget.busy ? _submit : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
