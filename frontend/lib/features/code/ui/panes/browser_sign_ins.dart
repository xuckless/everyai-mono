// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/motion/motion.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/anchored_popover.dart';
import '../../../../core/ui/every_icons.dart';
import '../../harness/everyai/browser_io.dart';
import '../../live/browser_jar.dart';
import '../../live/live_browsers.dart';
import '../../live/login_wall.dart';
import '../console/console_state.dart';
import 'browser_logins.dart';

// The session browser's sign-ins for people: the key menu in the Preview (this session's sign-ins, saved logins,
// clearing), signing in in a real Chrome window, and the card that asks the user to sign in while the agent waits.

/// Opens a real Chrome window at [url] on the project's profile for the user to sign in (sites such as Google refuse
/// a browser driven over DevTools), waits until they close it, then carries that site's sign-in into the session.
/// The headless browser restarts meanwhile: the page comes back where it was.
///
/// The window stops the project's Chrome, so every session of the project saves its jar first and gets its page
/// back afterwards. What comes over is every site whose sign-in the window changed (an OAuth sign-in sets the
/// provider's cookies and the app's), not only the one the window opened at.
///
/// One window per project's profile at a time: a second call (a double click, the card and the key menu) joins the
/// one open.
Future<void> signInInWindow(HeadlessBrowser b, String url) {
  if (_signInWindows[b.profileDir] case final open?) return open;
  final run = _signInInWindow(b, url);
  _signInWindows[b.profileDir] = run;
  return run.whenComplete(() {
    if (identical(_signInWindows[b.profileDir], run)) _signInWindows.remove(b.profileDir);
  });
}

final _signInWindows = <String, Future<void>>{};

Future<void> _signInInWindow(HeadlessBrowser b, String url) async {
  final here = b.page.value.url;
  final target = url.isEmpty || url == 'about:blank' ? 'https://accounts.google.com' : url;
  final siblings = [
    for (final o in LiveBrowsers.all)
      if (o is HeadlessBrowser && o.profileDir == b.profileDir && o.running) (browser: o, url: o.page.value.url),
  ];
  await Future.wait([for (final o in siblings) o.browser.saveJar().catchError((Object _) {})]);
  final before = b.jarHome == null ? null : await b.profileSignIns().catchError((Object _) => emptyJar);
  await b.close();
  await b.host.signIn(target);
  if (before != null) {
    final after = await b.profileSignIns();
    String key(Map<String, Object?> c) => '${c['name']}|${c['domain']}|${c['path']}|${c['value']}';
    final old = {for (final c in before.cookies) key(c)};
    final changed = {
      for (final c in after.cookies)
        if (!old.contains(key(c))) siteOf('${c['domain'] ?? ''}'),
    }..add(siteOf(Uri.tryParse(target)?.host ?? ''));
    for (final site in changed) {
      if (site.isNotEmpty) await b.applyJar(jarForSite(after, site));
    }
  }
  final back = here.isEmpty || here == 'about:blank' ? target : here;
  await b.userOpen(back);
  // The other sessions' pages went with Chrome: they come back where they were.
  for (final o in siblings) {
    if (identical(o.browser, b) || o.url.isEmpty || o.url == 'about:blank') continue;
    unawaited(o.browser.userOpen(o.url).catchError((Object _) {}));
  }
}

/// The saved logins, once the app's store is known (null in tests without one).
Future<SavedLogins?> _savedLogins() async {
  final store = LiveBrowsers.jars;
  if (store == null) return null;
  final l = SavedLogins.of(await store());
  await l.load();
  return l;
}

/// The key button in the Preview's bar: this session's sign-ins, saved logins for the project, and clearing.
class BrowserKeysButton extends StatelessWidget {
  const BrowserKeysButton({super.key, required this.browser, required this.projectId});

  final BrowserPage browser;
  final String? projectId;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (browser.jarHome == null) return const SizedBox.shrink();
    return Semantics(
      label: 'Sign-ins',
      button: true,
      child: AnchoredPopover(
        width: 340,
        builder: (panel, close) => _KeysPanel(browser: browser, projectId: projectId, close: close, host: context),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(EveryIcon.key.of(theme.design), size: 16, color: theme.textMuted),
        ),
      ),
    );
  }
}

class _KeysPanel extends StatefulWidget {
  const _KeysPanel({required this.browser, required this.projectId, required this.close, required this.host});

  final BrowserPage browser;
  final String? projectId;
  final VoidCallback close;

  /// The key button's context: still mounted after the panel closes, for dialogs.
  final BuildContext host;

  @override
  State<_KeysPanel> createState() => _KeysPanelState();
}

/// What the panel shows; loaded when it opens.
typedef _Keys = ({List<String> session, List<SavedLogin> saved, List<String> profile, SavedLogins? store});

class _KeysPanelState extends State<_KeysPanel> {
  _Keys? _keys;

  /// One action at a time (a second click while one runs does nothing).
  Future<void>? _busy;

  BrowserPage get _b => widget.browser;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final jar = _b.running ? await _b.captureJar() : null;
    final store = await _savedLogins().catchError((Object _) => null);
    final session = jar == null ? _b.signedInSites : jarSites(jar);
    final profile = _b.running
        ? jarSites(await _b.profileSignIns().catchError((Object _) => emptyJar))
        : const <String>[];
    if (!mounted) return;
    setState(
      () => _keys = (
        session: session,
        saved: store?.usable(widget.projectId) ?? const [],
        profile: [
          for (final s in profile)
            if (!session.contains(s)) s,
        ],
        store: store,
      ),
    );
  }

  void _run(Future<void> Function() action, {bool closes = false}) {
    if (_busy != null) return;
    final f = _busy = () async {
      try {
        await action();
      } on Object catch (e) {
        if (mounted) showAdaptiveToast(context, '$e');
      }
    }();
    unawaited(
      f.whenComplete(() {
        _busy = null;
        if (closes) {
          widget.close();
        } else if (mounted) {
          unawaited(_load());
        }
      }),
    );
  }

  Future<void> _save(String site, LoginScope scope) async {
    final store = _keys?.store;
    if (store == null) return;
    final jar = jarForSite(await _b.captureJar(), site);
    final l = await store.save(site, jar, scope: scope, projectId: widget.projectId);
    _b.usedLogins[site] = l.id;
    if (mounted) {
      showAdaptiveToast(
        context,
        'Saved the login for $site${scope == LoginScope.global ? ' for every project' : ' for this project'}.',
      );
    }
  }

  Future<void> _use(SavedLogin l) async {
    final data = await _keys?.store?.payload(l.id);
    if (data == null) throw StateError('That saved login is gone.');
    await _b.applyJar(data, site: l.site, loginId: l.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final k = _keys;
    if (k == null) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: AdaptiveProgress()),
      );
    }
    Widget label(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Text(text, style: theme.type.caption.semibold.tint(theme.textMuted)),
    );
    final rows = <Widget>[
      label('This session'),
      if (k.session.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Text('Not signed in anywhere yet.', style: theme.type.caption.tint(theme.textSubtle)),
        ),
      for (final site in k.session)
        PopoverRow(
          key: ValueKey('keys.session.$site'),
          title: site,
          subtitle: _b.usedLogins.containsKey(site) ? 'From a saved login' : null,
          trailing: AdaptiveMenuButton(
            tooltip: 'Options for $site',
            actions: [
              if (k.store != null) ...[
                MenuAction(
                  label: 'Save login for this project',
                  onSelected: () => _run(() => _save(site, LoginScope.project)),
                ),
                MenuAction(
                  label: 'Save login for every project',
                  onSelected: () => _run(() => _save(site, LoginScope.global)),
                ),
              ],
              MenuAction(
                label: 'Sign out',
                destructive: true,
                onSelected: () => _run(() => _b.clearJar(site: site)),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(EveryIcon.more.of(theme.design), size: 14, color: theme.textMuted),
            ),
          ),
        ),
      if (k.saved.isNotEmpty) label('Saved logins'),
      for (final l in k.saved)
        PopoverRow(
          key: ValueKey('keys.saved.${l.id}'),
          title: l.site,
          subtitle: [
            l.scope == LoginScope.global ? 'Every project' : 'This project',
            if (l.expired) 'Expired: sign in again, then save',
          ].join(' · '),
          onTap: () => _run(() => _use(l), closes: true),
          trailing: AdaptiveIconButton(
            icon: EveryIcon.delete,
            tooltip: 'Delete the saved login',
            size: 13,
            onPressed: () => _run(() => k.store!.delete(l.id)),
          ),
        ),
      if (k.profile.isNotEmpty) ...[
        label("In the project's browser"),
        for (final site in k.profile)
          PopoverRow(
            key: ValueKey('keys.profile.$site'),
            title: site,
            subtitle: 'Signed in in a window, or before sessions kept their own',
            onTap: () => _run(() async => _b.applyJar(await _b.profileSignIns(site: site)), closes: true),
          ),
      ],
      BrowserLoginRows(browser: _b, projectId: widget.projectId, close: widget.close, host: widget.host),
      const SizedBox(height: 4),
      // A window on the project's Chrome profile: Chrome pages only.
      if (_b case final HeadlessBrowser chrome)
        PopoverRow(
          title: 'Sign in in a window…',
          subtitle: 'A real Chrome window, for Google and other sites that refuse this one',
          onTap: () {
            widget.close();
            unawaited(signInInWindow(chrome, chrome.page.value.url).catchError((Object _) {}));
          },
        ),
      if (k.session.isNotEmpty)
        PopoverRow(
          title: 'Sign out of everything in this session',
          destructive: true,
          onTap: () => _run(() => _b.clearJar(), closes: true),
        ),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final (i, r) in rows.indexed) r.rowIn(i)],
      ),
    );
  }
}

/// "Sign in to github.com": the session's agent waits at a sign-in page. Above the composer and on the Board.
/// Take control shows the page in the Preview; a saved login for the site fills it in; Sign in in a window opens real
/// Chrome; Skip lets the agent carry on without. Nothing while no call waits.
///
/// No state of its own: it follows [LoginWall.waiting] and the session browser's [LoginWall.state].
class LoginWallCard extends ConsumerWidget {
  const LoginWallCard({super.key, required this.sessionId, this.projectId, this.onOpen});

  final String sessionId;
  final String? projectId;

  /// On the Board: opens the session (its Preview) instead of showing it here.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ValueListenableBuilder<List<LoginWall>>(
    valueListenable: LoginWall.waiting,
    builder: (context, waiting, _) {
      final b = LiveBrowsers.of(sessionId);
      if (b == null || !waiting.any((w) => identical(w, b.loginWall))) return const SizedBox.shrink();
      final state = b.loginWall.state.value;
      if (state is! WallWaiting) return const SizedBox.shrink();
      final theme = EveryTheme.of(context);
      void preview() {
        if (onOpen case final open?) return open();
        ref.read(consolePanelProvider(sessionId).notifier).show(ConsoleView.preview);
        b.control.take();
      }

      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Container(
          key: ValueKey('login-wall.$sessionId'),
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(
            color: theme.accentBg,
            border: Border.all(color: theme.accent.withValues(alpha: 0.6)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AdaptiveIcon(EveryIcon.key, size: 15, color: theme.accent),
                  const SizedBox(width: 10),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: 'Sign in to ${state.site}', style: theme.type.callout.semibold),
                        TextSpan(
                          text: '  · the agent waits until you have',
                          style: theme.type.caption.tint(theme.textMuted),
                        ),
                      ],
                    ),
                    style: theme.type.callout.tint(theme.text),
                  ),
                ],
              ),
              AdaptiveButton(
                key: ValueKey('login-wall.take.$sessionId'),
                label: onOpen == null ? 'Take control' : 'Open',
                onPressed: preview,
              ),
              _UseSavedLogin(browser: b, site: state.site, projectId: projectId),
              if (b case final HeadlessBrowser chrome when onOpen == null)
                AdaptiveButton(
                  label: 'Sign in in a window',
                  emphasis: ButtonEmphasis.secondary,
                  onPressed: () => unawaited(signInInWindow(chrome, state.url).catchError((Object _) {})),
                ),
              AdaptiveButton(
                key: ValueKey('login-wall.skip.$sessionId'),
                label: 'Skip',
                emphasis: ButtonEmphasis.secondary,
                onPressed: b.loginWall.skip,
              ),
            ],
          ),
        ).settle(),
      );
    },
  );
}

/// "Use saved login" when one for the site isn't expired.
class _UseSavedLogin extends StatefulWidget {
  const _UseSavedLogin({required this.browser, required this.site, required this.projectId});

  final BrowserPage browser;
  final String site;
  final String? projectId;

  @override
  State<_UseSavedLogin> createState() => _UseSavedLoginState();
}

class _UseSavedLoginState extends State<_UseSavedLogin> {
  SavedLogin? _login;
  SavedLogins? _store;
  Future<void>? _using;

  @override
  void initState() {
    super.initState();
    unawaited(
      _savedLogins().then((s) {
        if (!mounted || s == null) return;
        setState(() {
          _store = s;
          // Expired ones too, last: the wall that marked it may be wrong, and trying costs a reload.
          final all = s.usable(widget.projectId, site: widget.site);
          _login = all.where((l) => !l.expired).firstOrNull ?? all.firstOrNull;
        });
      }, onError: (Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = _login, s = _store;
    if (l == null || s == null) return const SizedBox.shrink();
    return AdaptiveButton(
      label: l.expired ? 'Try saved login' : 'Use saved login',
      emphasis: ButtonEmphasis.secondary,
      onPressed: () {
        _using ??= () async {
          final data = await s.payload(l.id);
          if (data != null) await widget.browser.applyJar(data, site: l.site, loginId: l.id);
        }().whenComplete(() => _using = null);
      },
    );
  }
}
