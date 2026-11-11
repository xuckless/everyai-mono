// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/anchored_popover.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../settings/settings_registry.dart';
import '../../../settings/ui/settings_modal.dart' show showSettings;
import '../../harness/everyai/browser_io.dart';
import '../../live/agent_logins.dart';
import '../../live/browser_jar.dart' show LoginScope;
import '../../live/live_browsers.dart';
import '../../live/login_wall.dart' show siteOf;
import '../logins_settings.dart';

// The Preview key menu's logins for people: fill the page with a saved login (the user's own fill, no card), save
// this page's login, stop allowing one in this session, delete one, and a way to Settings > Code > Logins.

/// Fills the sign-in form on [b]'s page with [e]: its username into the first visible username or email field, its
/// password into the first visible password field. What was filled, for a toast.
Future<String> fillPageWithLogin(BrowserPage b, LoginEntry e, AgentLogins store) async {
  final secrets = await store.secretsOf(e.id);
  if (secrets == null) throw StateError("'${e.name}' can't be read now.");
  final found = await b.evaluate(_markFieldsJs);
  final have = found is List ? found.cast<Object?>() : const <Object?>[];
  final filled = <String>[];
  if (have.contains('user') && e.username.isNotEmpty) {
    await b.typeSecret(e.username, selector: '[data-everyai-fill="user"]');
    filled.add('username');
  }
  if (have.contains('pass')) {
    await b.typeSecret(secrets.password, selector: '[data-everyai-fill="pass"]');
    filled.add('password');
  }
  if (filled.isEmpty) return 'This page has no sign-in field to fill.';
  return 'Filled the ${filled.join(' and ')} of ${e.name}.';
}

/// Marks the first visible username (or email) field and password field of the page with `data-everyai-fill`, and
/// returns which it found.
const _markFieldsJs = r'''
(() => {
  const shown = (el) => el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
  const fields = [...document.querySelectorAll('input')].filter(shown);
  for (const el of document.querySelectorAll('[data-everyai-fill]')) el.removeAttribute('data-everyai-fill');
  const pass = fields.find((el) => el.type === 'password');
  const userish = /user|email|login|account|name/i;
  const user = fields.find((el) => (el.autocomplete || '').includes('username')) ||
    fields.find((el) => el.type === 'email') ||
    fields.find((el) => ['text', ''].includes(el.type) && userish.test([el.name, el.id, el.placeholder].join(' ')));
  const out = [];
  if (user) { user.setAttribute('data-everyai-fill', 'user'); out.push('user'); }
  if (pass) { pass.setAttribute('data-everyai-fill', 'pass'); out.push('pass'); }
  return out;
})()''';

/// The Code session whose browser is [b], or null.
String? _sessionOf(BrowserPage b) =>
    LoginGate.all.map((g) => g.session).where((s) => identical(LiveBrowsers.of(s), b)).firstOrNull;

/// The key menu's logins part: "Fill a login" (this site's first), then Save this login… and Manage logins….
/// [host] stays mounted after the menu closes (the key button's context), for the dialogs.
class BrowserLoginRows extends StatefulWidget {
  const BrowserLoginRows({
    super.key,
    required this.browser,
    required this.projectId,
    required this.close,
    required this.host,
  });

  final BrowserPage browser;
  final String? projectId;
  final VoidCallback close;
  final BuildContext host;

  @override
  State<BrowserLoginRows> createState() => _BrowserLoginRowsState();
}

class _BrowserLoginRowsState extends State<BrowserLoginRows> {
  AgentLogins? _store;
  var _loaded = false;
  Future<void>? _busy;

  BrowserPage get _b => widget.browser;

  @override
  void initState() {
    super.initState();
    unawaited(
      AgentLogins.app().then((s) {
        if (mounted) setState(() => (_store = s, _loaded = true));
      }),
    );
  }

  void _run(Future<void> Function() action, {bool closes = true}) {
    if (_busy != null) return;
    final host = widget.host;
    if (closes) widget.close();
    _busy = () async {
      try {
        await action();
      } on Object catch (e) {
        if (host.mounted) showAdaptiveToast(host, '$e');
      }
    }().whenComplete(() => _busy = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final store = _store;
    if (!_loaded) return const SizedBox.shrink();
    final host = Uri.tryParse(_b.page.value.url)?.host ?? '';
    final site = host.isEmpty ? '' : siteOf(host);
    final session = _sessionOf(_b);
    final gate = session == null ? null : LoginGate.find(session);
    final all = store == null
        ? const <LoginEntry>[]
        : ([
            for (final l in store.entries.value)
              if (l.scope == LoginScope.global || l.projectId == widget.projectId) l,
          ]..sort((a, b) => (loginFitsHost(a.site, host) ? 0 : 1).compareTo(loginFitsHost(b.site, host) ? 0 : 1)));
    Widget label(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Text(text, style: theme.type.caption.semibold.tint(theme.textMuted)),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (all.isNotEmpty) label('Fill a login'),
        for (final l in all)
          PopoverRow(
            key: ValueKey('keys.login.${l.name}'),
            title: l.name,
            subtitle: [
              l.site,
              if (l.username.isNotEmpty) l.username,
              if (gate?.stateOf(l.name) is ConsentAllowed) 'Allowed this session',
            ].join(' · '),
            onTap: () => _run(() async {
              final said = await fillPageWithLogin(_b, l, store!);
              if (widget.host.mounted) showAdaptiveToast(widget.host, said);
            }),
            trailing: AdaptiveMenuButton(
              tooltip: 'Options for ${l.name}',
              actions: [
                MenuAction(
                  label: 'Fill this page',
                  onSelected: () => _run(() async {
                    final said = await fillPageWithLogin(_b, l, store!);
                    if (widget.host.mounted) showAdaptiveToast(widget.host, said);
                  }),
                ),
                if (gate?.stateOf(l.name) is ConsentAllowed)
                  MenuAction(label: 'Stop allowing', onSelected: () => _run(() async => gate!.revoke(l.name))),
                MenuAction(
                  label: 'Delete',
                  destructive: true,
                  onSelected: () => _run(() async {
                    final yes =
                        widget.host.mounted &&
                        await showAdaptiveConfirm(
                          widget.host,
                          title: 'Delete ${l.name}?',
                          message: 'Its password and authenticator secret go too.',
                          confirmLabel: 'Delete',
                          destructive: true,
                        );
                    if (yes) await store!.delete(l.id);
                  }),
                ),
              ],
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(EveryIcon.more.of(theme.design), size: 14, color: theme.textMuted),
              ),
            ),
          ),
        if (store != null)
          PopoverRow(
            key: const ValueKey('keys.save-login'),
            title: 'Save this login…',
            subtitle: site.isEmpty ? 'For agents to sign in with' : 'For agents to sign in to $site',
            onTap: () => _run(() async {
              if (!widget.host.mounted) return;
              await showLoginDialog(
                widget.host,
                store: store,
                projectId: widget.projectId,
                url: _b.page.value.url.startsWith('http') ? Uri.parse(_b.page.value.url).origin : '',
                codes: AgentLogins.readPolicy?.call().codes ?? true,
              );
            }),
          ),
        PopoverRow(
          key: const ValueKey('keys.manage-logins'),
          title: 'Manage logins…',
          onTap: () => _run(() async {
            if (widget.host.mounted) {
              await showSettings(widget.host, section: SettingsSection.logins, args: {'project': ?widget.projectId});
            }
          }),
        ),
      ],
    );
  }
}
