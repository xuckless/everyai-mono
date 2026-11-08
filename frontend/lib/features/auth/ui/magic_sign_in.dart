import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/motion/motion.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../auth_providers.dart';
import '../domain/auth_state.dart';

final _emailShape = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Magic-link sign-in, drawn from the controller's [MagicFlow]: the email,
/// then "check your inbox" with the code field while the app polls for the
/// link, or why the request ended.
class MagicSignIn extends ConsumerStatefulWidget {
  const MagicSignIn({super.key});

  @override
  ConsumerState<MagicSignIn> createState() => _MagicSignInState();
}

class _MagicSignInState extends ConsumerState<MagicSignIn> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  String? _localError;

  /// Rebuilds once "Send again" may be offered (30 s after a send).
  Timer? _resendTimer;

  @override
  void dispose() {
    _resendTimer?.cancel();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  void _ask() {
    final email = _email.text.trim();
    if (!_emailShape.hasMatch(email)) {
      setState(() => _localError = 'Enter your email address.');
      return;
    }
    setState(() => _localError = null);
    ref.read(authProvider.notifier).ask(email);
  }

  void _onCode(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 6) ref.read(authProvider.notifier).enterCode(digits);
  }

  void _armResend(Waiting w) {
    _resendTimer?.cancel();
    final left = w.sentAt.add(const Duration(seconds: 30)).difference(DateTime.now());
    if (left > Duration.zero) _resendTimer = Timer(left, () => mounted ? setState(() {}) : null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final auth = ref.watch(authProvider);
    ref.listen(authProvider, (prev, next) {
      final prevFlow = prev is SigningIn ? prev.flow : null;
      if (next case SigningIn(flow: final Waiting w) when prevFlow is! Waiting && prevFlow is! Verifying) {
        _code.clear();
        _armResend(w);
      }
    });
    final controller = ref.read(authProvider.notifier);
    final flow = switch (auth) {
      SigningIn(:final flow) => flow,
      _ => null,
    };
    final Widget body = switch (flow) {
      null || EnterEmail() || Requesting() => _EmailStep(
        controller: _email,
        busy: flow is Requesting,
        error: _localError ?? (flow is EnterEmail ? flow.error : null),
        onSubmit: _ask,
        onCancel: flow == null ? null : controller.cancelSignIn,
      ),
      Waiting() || Verifying() => _InboxStep(
        waiting: flow is Verifying ? flow.waiting : flow as Waiting,
        verifying: flow is Verifying,
        code: _code,
        onCode: _onCode,
        canResend:
            DateTime.now().difference((flow is Verifying ? flow.waiting : flow as Waiting).sentAt) >=
            const Duration(seconds: 30),
        onResend: () => controller.ask((flow is Verifying ? flow.waiting : flow as Waiting).email),
        onOtherEmail: () => controller.startSignIn(email: _email.text),
      ),
      Expired(:final email, :final reason) => _EndedStep(
        reason: reason,
        onResend: () => controller.ask(email),
        onOtherEmail: () => controller.startSignIn(email: email),
      ),
    };
    return AnimatedSwitcher(
      duration: Motion.swap,
      switchInCurve: Motion.easeOut,
      switchOutCurve: Motion.easeExit,
      child: KeyedSubtree(
        key: ValueKey(flow.runtimeType == Verifying ? Waiting : flow.runtimeType),
        child: DefaultTextStyle.merge(style: theme.type.body.tint(theme.text), child: body),
      ),
    );
  }
}

class _EmailStep extends StatelessWidget {
  const _EmailStep({
    required this.controller,
    required this.busy,
    required this.error,
    required this.onSubmit,
    required this.onCancel,
  });

  final TextEditingController controller;
  final bool busy;
  final String? error;
  final VoidCallback onSubmit;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          "We'll email you a link and a 6-digit code. No password.",
          style: theme.type.caption.tint(theme.textMuted),
        ),
        const SizedBox(height: 10),
        AdaptiveTextField(
          key: const ValueKey('magic.email'),
          controller: controller,
          placeholder: 'you@example.com',
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.send,
          autofocus: true,
          onSubmitted: (_) => onSubmit(),
        ),
        if (error != null) ...[
          const SizedBox(height: 6),
          Text(error!, key: const ValueKey('magic.error'), style: theme.type.caption.tint(theme.danger)),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            KitButton(key: const ValueKey('magic.send'), label: 'Email me a link', busy: busy, onPressed: onSubmit),
            if (onCancel != null) ...[
              const SizedBox(width: 8),
              KitButton(label: 'Cancel', style: KitButtonStyle.ghost, onPressed: onCancel),
            ],
          ],
        ),
      ],
    );
  }
}

class _InboxStep extends StatelessWidget {
  const _InboxStep({
    required this.waiting,
    required this.verifying,
    required this.code,
    required this.onCode,
    required this.canResend,
    required this.onResend,
    required this.onOtherEmail,
  });

  final Waiting waiting;
  final bool verifying;
  final TextEditingController code;
  final ValueChanged<String> onCode;
  final bool canResend;
  final VoidCallback onResend;
  final VoidCallback onOtherEmail;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Check your inbox', style: theme.type.headline.tint(theme.text)),
        const SizedBox(height: 2),
        Text(
          'We sent a link and a code to ${waiting.email}. Press Sign in in the email, on any device, or type the code.',
          style: theme.type.caption.tint(theme.textMuted),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: 200,
          child: AdaptiveTextField(
            key: const ValueKey('magic.code'),
            controller: code,
            placeholder: '6-digit code',
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            autofocus: true,
            onChanged: onCode,
            onSubmitted: onCode,
          ),
        ),
        const SizedBox(height: 8),
        if (waiting.codeError case final error?)
          Text(error, key: const ValueKey('magic.code-error'), style: theme.type.caption.tint(theme.danger))
        else
          ShimmerText(
            verifying ? 'Checking the code…' : 'Waiting for you to press Sign in…',
            style: theme.type.caption.tint(theme.textSubtle),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            KitButton(
              key: const ValueKey('magic.resend'),
              label: 'Send again',
              style: KitButtonStyle.soft,
              onPressed: canResend ? onResend : null,
            ),
            const SizedBox(width: 8),
            KitButton(label: 'Use another email', style: KitButtonStyle.ghost, onPressed: onOtherEmail),
          ],
        ),
      ],
    );
  }
}

class _EndedStep extends StatelessWidget {
  const _EndedStep({required this.reason, required this.onResend, required this.onOtherEmail});

  final String reason;
  final VoidCallback onResend;
  final VoidCallback onOtherEmail;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(reason, key: const ValueKey('magic.ended'), style: theme.type.callout.tint(theme.text)),
        const SizedBox(height: 12),
        Row(
          children: [
            KitButton(key: const ValueKey('magic.new'), label: 'Send a new email', onPressed: onResend),
            const SizedBox(width: 8),
            KitButton(label: 'Use another email', style: KitButtonStyle.ghost, onPressed: onOtherEmail),
          ],
        ),
      ],
    );
  }
}
