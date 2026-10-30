import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/brand.dart';
import '../auth_providers.dart';
import '../domain/auth_state.dart';

enum AuthMode { signIn, signUp }

/// Email/password and Google sign-in. Shown only when DEV_SKIP_AUTH is off.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key, required this.mode});

  final AuthMode mode;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _localError;

  bool get _signUp => widget.mode == AuthMode.signUp;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final email = _email.text.trim();
    final password = _password.text;
    final error = switch (null) {
      _ when _signUp && _name.text.trim().isEmpty => 'Enter your name.',
      _ when !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email) => 'Enter a valid email address.',
      _ when password.length < (_signUp ? 8 : 1) => _signUp ? 'Use at least 8 characters.' : 'Enter your password.',
      _ => null,
    };
    setState(() => _localError = error);
    if (error != null) return;
    final auth = ref.read(authProvider.notifier);
    if (_signUp) {
      auth.signUp(name: _name.text, email: email, password: password);
    } else {
      auth.signIn(email: email, password: password);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final state = ref.watch(authProvider);
    final busy = state is Authenticating;
    final error = _localError ?? (state is SignedOut ? state.error : null);

    return BrandField(
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SvgPicture.asset(
                      theme.isDark
                          ? 'assets/brand/logo/lockup-stacked-on-dark.svg'
                          : 'assets/brand/logo/lockup-stacked-on-light.svg',
                      height: 96,
                      semanticsLabel: 'EveryAI',
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _signUp ? 'Create your account' : 'Every model. One app.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.textMuted, fontSize: 15),
                    ),
                    const SizedBox(height: 28),
                    if (_signUp) ...[
                      AdaptiveTextField(
                        controller: _name,
                        placeholder: 'Name',
                        autofillHints: const [AutofillHints.name],
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 10),
                    ],
                    AdaptiveTextField(
                      controller: _email,
                      placeholder: 'Email',
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 10),
                    AdaptiveTextField(
                      controller: _password,
                      placeholder: 'Password',
                      obscureText: true,
                      autofillHints: [_signUp ? AutofillHints.newPassword : AutofillHints.password],
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(error, style: TextStyle(color: theme.danger, fontSize: 13)),
                      ),
                    ],
                    const SizedBox(height: 20),
                    AdaptiveButton(
                      label: _signUp ? 'Create account' : 'Sign in',
                      expand: true,
                      busy: busy && state.method != AuthMethod.google,
                      onPressed: _submit,
                    ),
                    if (AuthController.googleSupported) ...[
                      const SizedBox(height: 10),
                      AdaptiveButton(
                        label: 'Continue with Google',
                        emphasis: ButtonEmphasis.secondary,
                        expand: true,
                        icon: Image.asset('assets/google_logo.png', width: 18, height: 18),
                        busy: busy && state.method == AuthMethod.google,
                        onPressed: ref.read(authProvider.notifier).signInWithGoogle,
                      ),
                    ],
                    const SizedBox(height: 16),
                    AdaptiveButton(
                      label: _signUp ? 'I already have an account' : 'Create an account',
                      emphasis: ButtonEmphasis.plain,
                      onPressed: busy ? null : () => context.go(_signUp ? Routes.signIn : Routes.signUp),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
