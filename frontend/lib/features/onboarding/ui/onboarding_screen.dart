import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/version.dart';
import '../../../core/motion/motion.dart';
import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/brand.dart';
import '../../../core/ui/every_icons.dart';
import '../../code/domain/code_session.dart' show everyaiHarnessName;
import '../../code/drivers/driver_registry.dart';
import '../../code/code_settings_providers.dart';
import '../../code/migration/ui/bring_over_sheet.dart' show showBringOver;
import '../../code/ui/harness_setup_row.dart';
import '../../local_models/local_model_bridge.dart' show localDetectionProvider;
import '../../local_models/ui/local_models_section.dart' show LocalSetupCard;
import '../../settings/byok_keys.dart';
import '../../settings/domain/byok_providers.dart';
import '../../settings/domain/key_check.dart';
import '../domain/harness_rows.dart';
import '../git_bash_stub.dart';
import '../onboarding_harness_providers.dart';
import '../onboarding_providers.dart';

/// The terms the last step asks the user to accept; the same text as
/// TERMS-DEV.md at the repo root.
const devBuildTerms = [
  'EveryAI is provided as-is, with no warranty, for testing only.',
  'You are responsible for your API keys and what they cost. EveryAI never stores your keys on its server.',
  'Outside agents (Claude Code, Codex, OpenCode, Gemini CLI) run under their own terms and your own accounts.',
  'Code runs commands and edits files in folders you open. Review what it does and use version control.',
  'Chats and sessions are stored on this device only, and a new build may not read old data.',
  'The software is licensed under FSL-1.1-ALv2 (see LICENSE).',
];

/// The alpha entry screen: a short guided tour that ends with the user
/// accepting the dev-build terms. Shown once per [appVersion].
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.desktop});

  /// Whether the Code step lists the agents on this computer (desktops), or
  /// explains remote control (phones, tablets, web). Null: this host.
  final bool? desktop;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { welcome, bugs, keys, code, agree }

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int _index = 0;
  bool _agreed = false;

  static const _steps = _Step.values;

  bool get _desktop => widget.desktop ?? Host.isDesktop;

  _Step get _step => _steps[_index];

  void _next() => setState(() => _index = (_index + 1).clamp(0, _steps.length - 1));
  void _back() => setState(() => _index = (_index - 1).clamp(0, _steps.length - 1));

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final last = _index == _steps.length - 1;
    // The agents list needs more room than the other steps.
    final width = (_step == _Step.code || _step == _Step.keys) && _desktop ? 580.0 : 480.0;
    return ColoredBox(
      color: theme.background,
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 48,
              child: Padding(
                // On macOS the traffic lights sit in this row: start after them, as the sidebar does.
                padding: EdgeInsets.fromLTRB(Host.hasTrafficLights ? 92 : 22, 0, 22, 0),
                child: Row(
                  children: [
                    const BrandMark(size: 18),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'EveryAI',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.type.callout.semibold.tint(theme.text),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '$appVersion · alpha',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: theme.type.caption.mono.tint(theme.textSubtle),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: AnimatedContainer(
                  duration: Motion.reduced(context) ? Duration.zero : Motion.move,
                  curve: Motion.easeInOut,
                  constraints: BoxConstraints(maxWidth: width + 48),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _ProgressBar(step: _index, of: _steps.length),
                        const SizedBox(height: 28),
                        _StepView(
                          key: ValueKey(_step),
                          headline: _headline(_step),
                          child: switch (_step) {
                            _Step.welcome => const _Welcome(),
                            _Step.bugs => const _Bugs(),
                            _Step.keys => const _Keys(),
                            _Step.code => _desktop ? const _CodeHarnesses() : const _CodeRemote(),
                            _Step.agree => _Agree(agreed: _agreed, onChanged: (v) => setState(() => _agreed = v)),
                          },
                        ),
                        const SizedBox(height: 28),
                        // Back at the start; the others at the end, wrapping when they don't fit.
                        Row(
                          children: [
                            if (_index > 0)
                              KitButton(
                                key: const ValueKey('onboarding.back'),
                                label: 'Back',
                                style: KitButtonStyle.ghost,
                                onPressed: _back,
                              ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Wrap(
                                alignment: WrapAlignment.end,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 6,
                                runSpacing: 8,
                                children: [
                                  if (_step == _Step.keys)
                                    KitButton(
                                      key: const ValueKey('onboarding.skip'),
                                      label: 'Later',
                                      style: KitButtonStyle.ghost,
                                      onPressed: _next,
                                    ),
                                  if (last)
                                    KitButton(
                                      key: const ValueKey('onboarding.enter'),
                                      label: 'Enter EveryAI',
                                      large: true,
                                      onPressed: _agreed
                                          ? () => ref.read(onboardingAcceptedProvider.notifier).accept()
                                          : null,
                                    )
                                  else
                                    KitButton(
                                      key: const ValueKey('onboarding.next'),
                                      label: switch (_step) {
                                        _Step.welcome => 'Show me around',
                                        _Step.bugs => 'Got it',
                                        _ => 'Continue',
                                      },
                                      large: true,
                                      onPressed: _next,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _headline(_Step step) => switch (step) {
    _Step.welcome => "Hi. You're early.",
    _Step.bugs => 'Things will break.',
    _Step.keys => _desktop ? 'Pick a model to chat with.' : 'Chat runs on your key.',
    _Step.code => _desktop ? 'Code works with the agents you already use.' : 'Code runs on your computer.',
    _Step.agree => 'One last thing.',
  };
}

/// Where the tour is: one short pill per step, filled up to the current one (the newest fills from its left).
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.step, required this.of});

  final int step;
  final int of;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Semantics(
      label: 'Step ${step + 1} of $of',
      child: Row(
        children: [
          for (var i = 0; i < of; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: Container(
                  height: 3,
                  color: theme.border,
                  alignment: Alignment.centerLeft,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: i <= step ? 1 : 0),
                    duration: Motion.reduced(context) ? Duration.zero : Motion.move,
                    curve: Motion.easeInOut,
                    builder: (context, v, _) => FractionallySizedBox(
                      widthFactor: v,
                      heightFactor: 1,
                      child: ColoredBox(color: theme.accent),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A step: its headline types itself out, then the body fades in.
class _StepView extends StatefulWidget {
  const _StepView({super.key, required this.headline, required this.child});

  final String headline;
  final Widget child;

  @override
  State<_StepView> createState() => _StepViewState();
}

class _StepViewState extends State<_StepView> {
  bool _typed = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TypewriterText(
          widget.headline,
          style: theme.type.largeTitle.semibold.tint(theme.text),
          onDone: () => setState(() => _typed = true),
        ),
        const SizedBox(height: 18),
        AnimatedOpacity(
          opacity: _typed ? 1 : 0,
          duration: const Duration(milliseconds: 350),
          child: AnimatedSlide(
            offset: _typed ? Offset.zero : const Offset(0, 0.03),
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOut,
            // Not tappable until shown.
            child: IgnorePointer(ignoring: !_typed, child: widget.child),
          ),
        ),
      ],
    );
  }
}

/// Text that types itself out at about 30 characters a second, with a caret
/// while typing. A tap finishes it at once.
class TypewriterText extends StatefulWidget {
  const TypewriterText(this.text, {super.key, this.style, this.onDone});

  final String text;
  final TextStyle? style;
  final VoidCallback? onDone;

  static const perCharacter = Duration(milliseconds: 33);

  @override
  State<TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<TypewriterText> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: TypewriterText.perCharacter * widget.text.length,
  );

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone?.call();
    });
    unawaited(_controller.forward());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => _controller.value = 1,
    child: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final shown = (widget.text.length * _controller.value).round();
        final typing = _controller.value < 1;
        return Semantics(
          label: widget.text,
          excludeSemantics: true,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: widget.text.substring(0, shown)),
                // The caret while typing; the rest keeps its space so lines don't reflow.
                if (typing)
                  TextSpan(
                    text: '▍',
                    style: TextStyle(color: EveryTheme.of(context).accent),
                  ),
                if (typing)
                  TextSpan(
                    text: widget.text.substring(shown),
                    style: const TextStyle(color: Color(0x00000000)),
                  ),
              ],
            ),
            style: widget.style,
          ),
        );
      },
    ),
  );
}

/// A line with an icon in front, for the bullet lists.
class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.child, this.tint});

  final EveryIcon icon;
  final Widget child;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: AdaptiveIcon(icon, size: 17, color: tint ?? theme.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DefaultTextStyle.merge(style: theme.type.body.tint(theme.text), child: child),
          ),
        ],
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Text(
      'This is an alpha build of EveryAI: one workspace for chatting with any model and coding with '
      "any agent. It isn't finished, it isn't signed, and it changes every day. Here's what you need to know "
      'before you start.',
      style: theme.type.body.tint(theme.textMuted),
    );
  }
}

class _Bugs extends StatelessWidget {
  const _Bugs();

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Point(
          icon: EveryIcon.shield,
          tint: theme.warning,
          child: const Text('Bugs are likely. Features can change or disappear between builds.'),
        ),
        const _Point(
          icon: EveryIcon.devices,
          child: Text(
            "Your chats and sessions live on this device only. Keep a copy of anything you can't lose: a new build "
            'may not read old data.',
          ),
        ),
        const _Point(
          icon: EveryIcon.globe,
          child: Text(
            'The dev server sleeps when nobody uses it. If you see "Waking up the EveryAI server…", give it a few '
            'seconds.',
          ),
        ),
        _Point(
          icon: EveryIcon.help,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Found something? Write it up as a GitHub issue: what you did, what you expected, what happened, and '
                'this version. Issues are public, so leave out keys and private data.',
              ),
              const SizedBox(height: 8),
              AdaptiveButton(
                key: const ValueKey('onboarding.report'),
                label: 'Open GitHub issues',
                emphasis: ButtonEmphasis.secondary,
                icon: const AdaptiveIcon(EveryIcon.external, size: 14),
                onPressed: () => launchUrl(bugReportUri(), mode: LaunchMode.externalApplication),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A new GitHub issue with the version and platform already filled in.
Uri bugReportUri() => Uri.parse(issuesUrl).replace(
  queryParameters: {
    'body':
        '**What I did**\n\n\n**What I expected**\n\n\n**What happened**\n\n\n'
        '---\nVersion: $appVersion\nPlatform: ${kIsWeb ? 'web' : defaultTargetPlatform.name}\n',
  },
);

/// Step 3: paste a key, checked live, saved to the keychain.
class _Keys extends ConsumerStatefulWidget {
  const _Keys();

  @override
  ConsumerState<_Keys> createState() => _KeysState();
}

class _KeysState extends ConsumerState<_Keys> {
  final _field = TextEditingController();
  ByokProvider _provider = byokProviders.first;
  bool _checking = false;
  KeyCheck? _result;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final key = _field.text.trim();
    if (key.isEmpty) return;
    setState(() {
      _checking = true;
      _result = null;
    });
    final result = await ref.read(keyCheckProvider)(_provider, key);
    // A rejected key isn't kept; "couldn't tell" (offline) is, with the reason shown.
    if (result.valid != false) await ref.read(byokKeysProvider.notifier).save(_provider.id, key);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = result;
      if (result.valid != false) _field.clear();
    });
  }

  /// On a desktop: a model on this computer (first) or an API key.
  bool _onDevice = true;

  @override
  Widget build(BuildContext context) {
    // Off on phones and in tests: then this step is the key alone.
    final local = ref.watch(localDetectionProvider);
    if (!local) return _keyStep(context);
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, box) => KitSegmented<bool>(
            key: const ValueKey('onboarding.model-kind'),
            width: box.maxWidth,
            values: const [true, false],
            selected: _onDevice,
            label: (v) => v ? 'On this computer' : 'API key',
            onSelected: (v) => setState(() => _onDevice = v),
          ),
        ),
        const SizedBox(height: 18),
        StateSwap(
          alignment: Alignment.topCenter,
          child: _onDevice
              ? Column(
                  key: const ValueKey('onboarding.local'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Free and private: the model runs here, and your chats never leave this computer.',
                      style: theme.type.body.tint(theme.textMuted),
                    ),
                    const SizedBox(height: 16),
                    const LocalSetupCard(),
                  ],
                )
              : KeyedSubtree(key: const ValueKey('onboarding.keys'), child: _keyStep(context)),
        ),
      ],
    );
  }

  Widget _keyStep(BuildContext context) {
    final theme = EveryTheme.of(context);
    final saved = ref.watch(byokKeysProvider).value ?? const {};
    final result = _result;
    final ok = result != null && result.valid != false;
    final bad = result != null && result.valid == false;
    final ring = ok ? theme.success : (bad ? theme.danger : theme.border);
    final status = _checking
        ? const ShimmerText('Checking', key: ValueKey('checking'))
        : result != null
        ? Text(
            bad ? '${result.message} Nothing was saved.' : '${result.message}. Saved to this device\'s keychain.',
            key: const ValueKey('onboarding.key.result'),
            style: theme.type.callout.tint(bad ? theme.danger : (result.valid == true ? theme.success : theme.warning)),
          )
        : Text(
            saved.containsKey(_provider.id)
                ? '${_provider.name} key saved (…${ByokKeys.lastFour(saved[_provider.id]!)})'
                : _provider.blurb,
            key: ValueKey('hint.${_provider.id}'),
            style: theme.type.callout.tint(saved.containsKey(_provider.id) ? theme.success : theme.textSubtle),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Your key, your spend. EveryAI bills nothing on it.', style: theme.type.body.tint(theme.textMuted)),
        const SizedBox(height: 22),
        LayoutBuilder(
          builder: (context, box) => KitSegmented<ByokProvider>(
            width: box.maxWidth,
            values: byokProviders,
            selected: _provider,
            label: (p) => p.name,
            onSelected: (p) => setState(() {
              _provider = p;
              _result = null;
            }),
          ),
        ),
        const SizedBox(height: 12),
        AnimatedContainer(
          duration: Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 220),
          curve: Motion.easeInOut,
          height: 46,
          padding: const EdgeInsets.fromLTRB(4, 0, 7, 0),
          decoration: BoxDecoration(
            color: theme.well,
            borderRadius: BorderRadius.circular(EveryTheme.rowRadius + 3),
            border: Border.all(color: ring, width: ok || bad ? 1.5 : 1),
          ),
          child: Row(
            children: [
              Expanded(
                child: AdaptiveTextField(
                  key: const ValueKey('onboarding.key'),
                  controller: _field,
                  borderless: true,
                  placeholder: _provider.keyHint,
                  obscureText: true,
                  onChanged: (_) {
                    if (_result != null) setState(() => _result = null);
                  },
                  onSubmitted: (_) => _save(),
                ),
              ),
              StateSwap(
                child: ok
                    ? AdaptiveIcon(EveryIcon.check, key: const ValueKey('ok'), size: 16, color: theme.success)
                    : bad
                    ? AdaptiveIcon(EveryIcon.close, key: const ValueKey('bad'), size: 16, color: theme.danger)
                    : const SizedBox(key: ValueKey('none'), width: 16),
              ),
              const SizedBox(width: 8),
              KitButton(
                key: const ValueKey('onboarding.key.save'),
                label: 'Check',
                style: KitButtonStyle.soft,
                onPressed: _checking ? null : _save,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 20,
          child: Padding(
            padding: const EdgeInsets.only(left: 2),
            child: StateSwap(alignment: Alignment.centerLeft, child: status),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            KitButton(
              label: 'Get ${'AEIOU'.contains(_provider.name[0]) ? 'an' : 'a'} ${_provider.name} key',
              style: KitButtonStyle.ghost,
              icon: EveryIcon.external,
              onPressed: () => launchUrl(Uri.parse(_provider.keysUrl), mode: LaunchMode.externalApplication),
            ),
          ],
        ),
      ],
    );
  }
}

/// Step 4 on a desktop: the coding agents found on this computer, one row each with its one button.
class _CodeHarnesses extends ConsumerWidget {
  const _CodeHarnesses();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final own = ref.watch(codeSettingsProvider.select((s) => s.ownClis));
    final drivers = ref.watch(driverRegistryProvider).listed.toList();
    ref.watch(driverStatusesProvider);
    final scan = ref.read(driverStatusesProvider.notifier).appScan;
    final done = ref.watch(driverStatusesProvider).hasValue;
    final gitMissing = ref.watch(gitBashMissingProvider);
    final rows = harnessRows(
      drivers,
      ref.watch(harnessEnvStatusesProvider),
      hideAbsent: true,
      appFound: scan.offersSetUp,
      builtInBlocked: gitMissing,
    );
    // Until the first check ends there are no statuses, so every harness reads "Checking…".
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'EveryAI drives the coding agents installed on this computer, on your own plans, and adds its workflows '
          'and checks on top. Here is what it found:',
          style: theme.type.body.tint(theme.textMuted),
        ),
        const SizedBox(height: 14),
        const GitForWindowsNotice(),
        for (final r in rows)
          HarnessSetupRow(
            key: ValueKey('onboarding.harness.${r.id}${r.keySuffix}'),
            row: r,
            title: r.id == everyaiHarnessName ? "EveryAI's own agent" : null,
            statusLine: r.id == everyaiHarnessName
                ? (gitMissing ? 'Needs Git for Windows to run commands' : 'Runs on the key from the last step')
                : null,
            unknownLine: "Couldn't check. You can check again in Settings → Code → Harnesses.",
            offerMissing: false,
            trailing: [
              // A subscription CLI is set up only once the user has agreed to use it, so the choice comes first.
              if (r.driver.info.needsConsent && r.env.isHost)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: AdaptiveButton(
                    key: ValueKey('onboarding.consent.${r.id}${r.keySuffix}'),
                    label: own.contains(r.driver.info.consentId)
                        ? 'In use ✓'
                        : (r.state == RowState.ready ? 'Use it' : 'Allow'),
                    emphasis: own.contains(r.driver.info.consentId) ? ButtonEmphasis.secondary : ButtonEmphasis.primary,
                    onPressed: () => ref
                        .read(codeSettingsProvider.notifier)
                        .setOwnCli(r.driver.info.consentId, !own.contains(r.driver.info.consentId)),
                  ),
                ),
            ],
          ),
        if (done && rows.every((r) => r.id == everyaiHarnessName))
          Padding(
            key: const ValueKey('onboarding.none-found'),
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'No other coding agents found yet. You can add one later in Settings → Code → Harnesses.',
              style: theme.type.caption.tint(theme.textMuted),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          'Claude Code and Gemini CLI run on your own subscription, so EveryAI asks before using them. Change any of '
          'this in Settings → Code → Harnesses.',
          style: theme.type.caption.tint(theme.textMuted),
        ),
        const SizedBox(height: 4),
        AdaptiveButton(
          key: const ValueKey('onboarding.import'),
          label: 'Bring over from other tools',
          emphasis: ButtonEmphasis.plain,
          onPressed: () => showBringOver(context),
        ),
      ],
    );
  }
}

/// Step 4 on phones, tablets and the web.
class _CodeRemote extends StatelessWidget {
  const _CodeRemote();

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Text(
      'Coding agents run on your computer: install EveryAI there, then pair this device in Settings → Remote to '
      'follow and steer its sessions from here.',
      style: theme.type.body.tint(theme.textMuted),
    );
  }
}

/// Step 5: the terms and the checkbox that unlocks "Enter EveryAI".
class _Agree extends StatefulWidget {
  const _Agree({required this.agreed, required this.onChanged});

  final bool agreed;
  final ValueChanged<bool> onChanged;

  @override
  State<_Agree> createState() => _AgreeState();
}

class _AgreeState extends State<_Agree> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          key: const ValueKey('onboarding.agree'),
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onChanged(!widget.agreed),
          child: Semantics(
            checked: widget.agreed,
            button: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 20,
                  height: 20,
                  margin: const EdgeInsets.only(top: 1),
                  decoration: BoxDecoration(
                    color: widget.agreed ? theme.primary : null,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: widget.agreed ? theme.primary : theme.border, width: 1.5),
                  ),
                  child: widget.agreed
                      ? Center(child: AdaptiveIcon(EveryIcon.check, size: 13, color: theme.onPrimary))
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "I understand this is an experimental alpha build that may have bugs and lose data. I'll "
                    'use it for testing until it is stable, and I accept the Dev Build Terms.',
                    style: theme.type.body.tint(theme.text),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        AdaptiveButton(
          key: const ValueKey('onboarding.terms'),
          label: _open ? 'Hide the Dev Build Terms' : 'Read the Dev Build Terms',
          emphasis: ButtonEmphasis.plain,
          onPressed: () => setState(() => _open = !_open),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          child: _open
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final t in devBuildTerms)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text('•  $t', style: theme.type.callout.tint(theme.textMuted)),
                        ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
