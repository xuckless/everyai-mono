// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../settings/settings_registry.dart';
import '../../settings/ui/settings_modal.dart' show SettingsAnchor;
import '../code_providers.dart';
import '../live/agent_logins.dart';
import '../live/browser_jar.dart' show LoginScope;
import '../live/login_import.dart';
import '../live/totp.dart';

// Settings > Code > Logins: the logins agents may fill (name, site, username; the values stay hidden), importing
// them from a password manager, the answers given in sessions when the user wants to be asked, and the four switches.

/// The four switches as Settings shows them: preference key, title, what on means.
const _switches = [
  (
    LoginPolicy.prefWithoutAsking,
    'Agents use logins without asking',
    'Off: the first use of a login in a session waits for your Allow.',
  ),
  (
    LoginPolicy.prefSecretFields,
    'Agents may type into password fields',
    'Off: only a saved login reaches password, code and payment fields.',
  ),
  (
    LoginPolicy.prefCodes,
    'Store authenticator codes',
    'A login may keep its authenticator secret, and agents type the current code.',
  ),
  (LoginPolicy.prefAnySite, 'Fill on any site', 'Off: a login fills only on its own site and its subdomains.'),
];

class LoginsSettingsBody extends ConsumerStatefulWidget {
  const LoginsSettingsBody({super.key, this.projectId, this.store});

  /// The project new logins are for by default.
  final String? projectId;

  /// Tests: the logins to show instead of the app's.
  final AgentLogins? store;

  @override
  ConsumerState<LoginsSettingsBody> createState() => _LoginsSettingsBodyState();
}

/// Where the page's logins are: loading, ready, or unavailable (no keychain, or no store here).
sealed class _Load {
  const _Load();
}

final class _Loading extends _Load {
  const _Loading();
}

final class _Ready extends _Load {
  const _Ready(this.store);
  final AgentLogins store;
}

final class _Unavailable extends _Load {
  const _Unavailable();
}

class _LoginsSettingsBodyState extends ConsumerState<LoginsSettingsBody> {
  _Load _load = const _Loading();

  /// One action at a time (a second click while one runs does nothing).
  Future<void>? _busy;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    AgentLogins? s = widget.store;
    if (s != null) {
      await s.load().catchError((Object _) {});
    } else {
      s = await AgentLogins.app();
    }
    if (!mounted) return;
    setState(() => _load = s == null ? const _Unavailable() : _Ready(s));
  }

  void _run(Future<void> Function() action) {
    if (_busy != null) return;
    final f = _busy = () async {
      try {
        await action();
      } on Object catch (e) {
        if (mounted) showAdaptiveToast(context, '$e');
      }
    }();
    unawaited(f.whenComplete(() => _busy = null));
  }

  LoginPolicy get _policy => LoginPolicy.read((k) => ref.read(preferencesProvider)[k]);

  Future<void> _edit(AgentLogins store, {LoginEntry? entry}) async {
    final saved = await showLoginDialog(
      context,
      store: store,
      entry: entry,
      projectId: widget.projectId,
      codes: _policy.codes,
    );
    if (saved != null && mounted) showAdaptiveToast(context, 'Saved ${saved.name}.');
  }

  Future<void> _import(AgentLogins store) async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'CSV', extensions: ['csv'], uniformTypeIdentifiers: ['public.comma-separated-values-text']),
      ],
    );
    if (file == null) return;
    final parsed = parseLoginCsv(utf8.decode(await file.readAsBytes(), allowMalformed: true));
    if (!mounted) return;
    final scope = await _pickScope(parsed.logins.length, parsed.format);
    if (scope == null) return;
    final r = await store.importAll(parsed.logins, scope: scope, projectId: widget.projectId, codes: _policy.codes);
    if (mounted) {
      showAdaptiveToast(
        context,
        'Imported ${r.added} from ${parsed.format.label}'
        '${r.skipped + parsed.skipped == 0 ? '' : '; left out ${r.skipped + parsed.skipped} (already saved or incomplete)'}.',
      );
    }
  }

  /// Every project or this one, for an import of [n] logins.
  Future<LoginScope?> _pickScope(int n, LoginCsvFormat format) => showKitDialog<LoginScope>(
    context,
    builder: (ctx) => KitDialog(
      title: 'Import $n logins from ${format.label}?',
      body: const Text(
        'They are sealed on this computer with a key in your keychain. Delete the exported file afterwards: it holds '
        'your passwords in plain text.',
      ),
      actions: [
        KitButton(label: 'Cancel', style: KitButtonStyle.ghost, onPressed: () => Navigator.of(ctx).pop()),
        if (widget.projectId != null)
          KitButton(
            label: 'For this project',
            style: KitButtonStyle.soft,
            onPressed: () => Navigator.of(ctx).pop(LoginScope.project),
          ),
        KitButton(label: 'For every project', onPressed: () => Navigator.of(ctx).pop(LoginScope.global)),
      ],
    ),
  );

  Future<void> _deleteAll(AgentLogins store) async {
    final yes = await showAdaptiveConfirm(
      context,
      title: 'Delete all logins?',
      message: 'Every saved login goes, with its password and authenticator secret, and every approval of it.',
      confirmLabel: 'Delete all',
      destructive: true,
    );
    if (yes) await store.deleteAll();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final prefs = ref.watch(preferencesProvider);
    final load = _load;
    final store = load is _Ready ? load.store : null;
    final projects = ref.watch(codeProjectsProvider);
    String scopeOf(LoginEntry l) => l.scope == LoginScope.global
        ? 'Every project'
        : 'Only ${projects.where((p) => p.id == l.projectId).firstOrNull?.name ?? 'a removed project'}';
    return KitGroupedList(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Text(
            'Agents sign in with these by name. They never see the passwords or codes. A code sent by text or email '
            'still needs you.',
            style: theme.type.callout.tint(theme.textMuted),
          ),
        ),
        const AdaptiveSectionHeader('Saved logins'),
        switch (load) {
          _Loading() => const AdaptiveListTile(title: Text('Loading…')),
          _Unavailable() => AdaptiveListTile(
            title: Text("Logins can't be opened here", style: theme.type.body.tint(theme.textMuted)),
            subtitle: const Text('The keychain refused, or this computer has no app data folder.'),
          ),
          _Ready() => const SizedBox.shrink(),
        },
        if (store != null)
          ValueListenableBuilder<List<LoginEntry>>(
            valueListenable: store.entries,
            builder: (context, entries, _) => _LoginTable(
              entries: entries,
              scopeOf: scopeOf,
              onEdit: (l) => _run(() => _edit(store, entry: l)),
              onDelete: (l) => _run(() => store.delete(l.id)),
              onToggle: (l, on) => _run(() => store.setAgentsCanUse(l.id, on)),
              onAdd: () => _run(() => _edit(store)),
            ),
          ),
        if (store != null)
          SettingsAnchor(
            section: SettingsSection.logins,
            id: 'import',
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  KitButton(
                    key: const ValueKey('logins.add'),
                    label: 'Add login',
                    icon: EveryIcon.add,
                    style: KitButtonStyle.soft,
                    onPressed: () => _run(() => _edit(store)),
                  ),
                  KitButton(
                    key: const ValueKey('logins.import'),
                    label: 'Import from CSV…',
                    style: KitButtonStyle.soft,
                    onPressed: () => _run(() => _import(store)),
                  ),
                  ValueListenableBuilder<List<LoginEntry>>(
                    valueListenable: store.entries,
                    builder: (context, entries, _) => entries.isEmpty
                        ? const SizedBox.shrink()
                        : KitButton(
                            key: const ValueKey('logins.delete-all'),
                            label: 'Delete all logins…',
                            style: KitButtonStyle.ghost,
                            onPressed: () => _run(() => _deleteAll(store)),
                          ),
                  ),
                ],
              ),
            ),
          ),
        const SettingsAnchor(section: SettingsSection.logins, id: 'approvals', child: _Approvals()),
        const AdaptiveSectionHeader('Agents and logins'),
        for (final (key, title, detail) in _switches)
          SettingsAnchor(
            section: SettingsSection.logins,
            id: key == LoginPolicy.prefCodes ? 'codes' : key,
            child: AdaptiveListTile(
              key: ValueKey('logins.switch.$key'),
              title: Text(title),
              subtitle: Text(detail),
              trailing: KitSwitch(
                value: prefs[key] != '0',
                semanticLabel: title,
                onChanged: (v) => setState(() => prefs[key] = v ? '1' : '0'),
              ),
            ),
          ),
      ],
    );
  }
}

/// The logins as a table: name · site · username · ••••• · 2FA, the "Agents can use" switch, and edit and delete on
/// every row; + and − under it (− and Delete remove the selected row).
class _LoginTable extends StatefulWidget {
  const _LoginTable({
    required this.entries,
    required this.scopeOf,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
    required this.onAdd,
  });

  final List<LoginEntry> entries;
  final String Function(LoginEntry) scopeOf;
  final ValueChanged<LoginEntry> onEdit;
  final ValueChanged<LoginEntry> onDelete;
  final void Function(LoginEntry, bool) onToggle;
  final VoidCallback onAdd;

  @override
  State<_LoginTable> createState() => _LoginTableState();
}

class _LoginTableState extends State<_LoginTable> {
  /// The selected row's login id (not its index: a list changed elsewhere never moves it onto another row).
  String? _selected;
  final _focus = FocusNode(debugLabel: 'logins-table');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  LoginEntry? get _selectedEntry => widget.entries.where((l) => l.id == _selected).firstOrNull;

  void _removeSelected() {
    if (_selectedEntry case final l?) widget.onDelete(l);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final rows = widget.entries;
    return Focus(
      focusNode: _focus,
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent &&
            (e.logicalKey == LogicalKeyboardKey.delete || e.logicalKey == LogicalKeyboardKey.backspace) &&
            _selectedEntry != null) {
          _removeSelected();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: KitCard(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.all(14),
                child: Text('No logins yet', style: theme.type.callout.tint(theme.textSubtle)),
              ),
            for (final l in rows)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setState(() => _selected = l.id);
                  _focus.requestFocus();
                },
                onDoubleTap: () => widget.onEdit(l),
                child: Container(
                  key: ValueKey('logins.row.${l.name}'),
                  color: _selected == l.id ? theme.accentBg : null,
                  padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l.name,
                              style: theme.type.callout.mono.tint(l.agentsCanUse ? theme.text : theme.textMuted),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              [
                                l.site,
                                if (l.username.isNotEmpty) l.username,
                                '•••••',
                                if (l.hasCode) '2FA',
                                widget.scopeOf(l),
                              ].join(' · '),
                              style: theme.type.caption.tint(theme.textSubtle),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      KitSwitch(
                        key: ValueKey('logins.use.${l.name}'),
                        value: l.agentsCanUse,
                        semanticLabel: 'Agents can use ${l.name}',
                        onChanged: (v) => widget.onToggle(l, v),
                      ),
                      const SizedBox(width: 4),
                      AdaptiveIconButton(
                        key: ValueKey('logins.edit.${l.name}'),
                        icon: EveryIcon.edit,
                        tooltip: 'Edit ${l.name}',
                        size: 14,
                        onPressed: () => widget.onEdit(l),
                      ),
                      AdaptiveIconButton(
                        key: ValueKey('logins.delete.${l.name}'),
                        icon: EveryIcon.close,
                        tooltip: 'Delete ${l.name}',
                        size: 14,
                        onPressed: () => widget.onDelete(l),
                      ),
                    ],
                  ),
                ),
              ),
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: theme.border)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  AdaptiveIconButton(
                    key: const ValueKey('logins.plus'),
                    icon: EveryIcon.add,
                    tooltip: 'Add a login',
                    size: 14,
                    onPressed: widget.onAdd,
                  ),
                  AdaptiveIconButton(
                    key: const ValueKey('logins.minus'),
                    icon: EveryIcon.minus,
                    tooltip: 'Delete the selected login',
                    size: 14,
                    onPressed: _selectedEntry == null ? null : _removeSelected,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The answers given in sessions this run (the user wants to be asked first): each with a × that asks again next
/// time, and Forget all.
class _Approvals extends ConsumerWidget {
  const _Approvals();

  @override
  Widget build(BuildContext context, WidgetRef ref) => ValueListenableBuilder<int>(
    valueListenable: LoginGate.changes,
    builder: (context, _, _) {
      final answered = LoginGate.answered;
      if (answered.isEmpty) return const SizedBox.shrink();
      final theme = EveryTheme.of(context);
      final sessions = ref.read(codeSessionsProvider.notifier);
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const KitLabel('Answers in sessions', padding: EdgeInsets.fromLTRB(8, 0, 8, 8)),
            KitCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  for (final a in answered)
                    AdaptiveListTile(
                      key: ValueKey('logins.answer.${a.gate.session}.${a.login}'),
                      title: Text('${a.allowed ? 'Allowed' : 'Denied'}: ${a.login}'),
                      subtitle: Text(
                        '${sessions.byId(a.gate.session)?.title.trim().isNotEmpty == true ? sessions.byId(a.gate.session)!.title : 'A session'} · this session',
                      ),
                      trailing: AdaptiveIconButton(
                        icon: EveryIcon.close,
                        tooltip: a.allowed ? 'Stop allowing' : 'Forget',
                        size: 14,
                        onPressed: () => a.gate.revoke(a.login),
                      ),
                    ),
                ],
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: KitButton(
                  label: 'Forget all approvals',
                  style: KitButtonStyle.ghost,
                  onPressed: LoginGate.revokeAll,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Text('Answers last until the session ends.', style: theme.type.caption.tint(theme.textSubtle)),
            ),
          ],
        ),
      );
    },
  );
}

/// Adds a login, or edits [entry]: name, address, username, password (kept when left empty on an edit), the
/// authenticator secret (with [codes] on), and every project or [projectId]. The saved login, or null.
Future<LoginEntry?> showLoginDialog(
  BuildContext context, {
  required AgentLogins store,
  LoginEntry? entry,
  String? projectId,
  String? url,
  String? username,
  required bool codes,
}) => showKitDialog<LoginEntry>(
  context,
  builder: (_) =>
      _LoginDialog(store: store, entry: entry, projectId: projectId, url: url, username: username, codes: codes),
);

class _LoginDialog extends StatefulWidget {
  const _LoginDialog({required this.store, this.entry, this.projectId, this.url, this.username, required this.codes});

  final AgentLogins store;
  final LoginEntry? entry;
  final String? projectId;
  final String? url;
  final String? username;
  final bool codes;

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  late final _name = TextEditingController(text: widget.entry?.name ?? '');
  late final _url = TextEditingController(text: widget.entry?.url ?? widget.url ?? '');
  late final _user = TextEditingController(text: widget.entry?.username ?? widget.username ?? '');
  final _password = TextEditingController();
  final _totp = TextEditingController();
  late LoginScope _scope = widget.entry?.scope ?? (widget.projectId == null ? LoginScope.global : LoginScope.project);
  late bool _removeCode = false;
  String? _error;
  Future<void>? _saving;

  @override
  void dispose() {
    for (final c in [_name, _url, _user, _password, _totp]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (_saving != null) return;
    _saving = () async {
      try {
        final name = _name.text.trim().isEmpty
            ? widget.store.freeName(loginSiteOf(_url.text).split('.').first)
            : _name.text;
        final saved = await widget.store.save(
          id: widget.entry?.id,
          name: name,
          url: _url.text,
          username: _user.text,
          password: _password.text.isEmpty && widget.entry != null ? null : _password.text,
          totp: !widget.codes ? null : (_removeCode ? '' : (_totp.text.trim().isEmpty ? null : _totp.text)),
          scope: _scope,
          projectId: widget.entry?.projectId ?? widget.projectId,
          agentsCanUse: widget.entry?.agentsCanUse ?? true,
        );
        if (mounted) Navigator.of(context).pop(saved);
      } on LoginSaveError catch (e) {
        if (mounted) setState(() => _error = e.message);
      }
    }().whenComplete(() => _saving = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Text(text, style: theme.type.caption.semibold.tint(theme.textMuted)),
    );
    final editing = widget.entry != null;
    final hasCode = widget.entry?.hasCode ?? false;
    final totpOk = _totp.text.trim().isEmpty || parseTotp(_totp.text) != null;
    return KitDialog(
      title: editing ? 'Edit ${widget.entry!.name}' : 'Add a login',
      width: 460,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          label('Name agents use'),
          AdaptiveTextField(
            key: const ValueKey('login.name'),
            controller: _name,
            placeholder: 'github, staging-admin',
            autofocus: !editing,
          ),
          label('Site'),
          AdaptiveTextField(
            key: const ValueKey('login.url'),
            controller: _url,
            placeholder: 'https://github.com/login',
            keyboardType: TextInputType.url,
          ),
          label('Username'),
          AdaptiveTextField(
            key: const ValueKey('login.username'),
            controller: _user,
            placeholder: 'Email or username',
            autofillHints: const [AutofillHints.username],
          ),
          label('Password'),
          AdaptiveTextField(
            key: const ValueKey('login.password'),
            controller: _password,
            obscureText: true,
            placeholder: editing ? 'Leave empty to keep it' : 'Password',
            autofillHints: const [AutofillHints.password],
          ),
          if (widget.codes) ...[
            label('Authenticator secret (optional)'),
            if (hasCode && !_removeCode)
              Row(
                children: [
                  Expanded(child: Text('Saved', style: theme.type.callout)),
                  KitButton(
                    label: 'Remove',
                    style: KitButtonStyle.ghost,
                    onPressed: () => setState(() => _removeCode = true),
                  ),
                ],
              )
            else ...[
              AdaptiveTextField(
                key: const ValueKey('login.totp'),
                controller: _totp,
                obscureText: true,
                placeholder: 'Setup key or otpauth:// address',
                onChanged: (_) => setState(() {}),
              ),
              if (!totpOk)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text("That isn't an authenticator secret.", style: theme.type.caption.tint(theme.danger)),
                ),
            ],
          ],
          if (widget.projectId != null && !editing) ...[
            label('For'),
            KitSegmented<LoginScope>(
              values: const [LoginScope.project, LoginScope.global],
              selected: _scope,
              label: (s) => s == LoginScope.project ? 'This project' : 'Every project',
              onSelected: (s) => setState(() => _scope = s),
            ),
          ],
          if (_error case final e?)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(e, style: theme.type.caption.tint(theme.danger)),
            ),
        ],
      ),
      actions: [
        KitButton(label: 'Cancel', style: KitButtonStyle.ghost, onPressed: () => Navigator.of(context).pop()),
        KitButton(key: const ValueKey('login.save'), label: 'Save', onPressed: _save),
      ],
    );
  }
}
