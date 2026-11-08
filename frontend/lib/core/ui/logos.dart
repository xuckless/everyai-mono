import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/every_theme.dart';
import 'brand.dart';
import 'kit.dart';

/// Vendor, harness and app logos from Lobe Icons (MIT; see THIRD_PARTY_NOTICES.md), in `assets/logos/`. A name
/// ending in `-color` keeps its own colours; the others are one-colour marks drawn in the text colour, so black
/// logos (OpenAI, xAI, Cursor) still read in the dark theme.
final class Logo {
  const Logo._(this.name);

  /// The file under `assets/logos/`, without `.svg`.
  final String name;

  String get asset => 'assets/logos/$name.svg';

  /// A file under `assets/logos/` by name (`providers.json`'s `logo`); null for none.
  static Logo? file(String name) => name.isEmpty ? null : Logo._(name);
  bool get colored => name.endsWith('-color');

  /// The EveryAI mark, drawn from the brand kit instead.
  static const everyai = Logo._('everyai');

  /// The logo for a model vendor's catalog slug (`anthropic`, `moonshotai`, …), or null when there is none.
  static Logo? vendor(String slug) => switch (slug.replaceFirst('~', '')) {
    'everyai' => everyai,
    'openai' => const Logo._('openai'),
    'anthropic' => const Logo._('claude-color'),
    'google' => const Logo._('gemini-color'),
    'x-ai' => const Logo._('grok'),
    'qwen' || 'alibaba' => const Logo._('qwen-color'),
    'mistralai' || 'mistral' => const Logo._('mistral-color'),
    'z-ai' || 'thudm' => const Logo._('zai'),
    'deepseek' => const Logo._('deepseek-color'),
    'nvidia' => const Logo._('nvidia-color'),
    'moonshotai' => const Logo._('kimi'),
    'tencent' => const Logo._('hunyuan-color'),
    'meta' || 'meta-llama' => const Logo._('meta-color'),
    'openrouter' => const Logo._('openrouter-color'),
    'aion-labs' => const Logo._('aionlabs-color'),
    'cohere' => const Logo._('cohere-color'),
    'bytedance' || 'bytedance-seed' => const Logo._('bytedance-color'),
    'minimax' => const Logo._('minimax-color'),
    'xiaomi' => const Logo._('xiaomimimo'),
    'amazon' => const Logo._('nova-color'),
    'perplexity' => const Logo._('perplexity-color'),
    'inclusionai' => const Logo._('ling-color'),
    'sakana' => const Logo._('sakana-color'),
    'inception' => const Logo._('inception'),
    'liquid' => const Logo._('liquid'),
    'stepfun' || 'stepfun-ai' => const Logo._('stepfun-color'),
    'upstage' => const Logo._('upstage-color'),
    'rekaai' => const Logo._('reka'),
    'relace' => const Logo._('relace'),
    'morph' => const Logo._('morph-color'),
    'ibm-granite' => const Logo._('ibm'),
    'dots-studio' => const Logo._('dotsstudio'),
    'meituan' => const Logo._('longcat-color'),
    'nousresearch' => const Logo._('nousresearch'),
    'microsoft' => const Logo._('microsoft-color'),
    'fireworks' => const Logo._('fireworks-color'),
    'essentialai' => const Logo._('essentialai-color'),
    'huggingface' => const Logo._('huggingface-color'),
    'ollama' => const Logo._('ollama'),
    'lmstudio' => const Logo._('lmstudio'),
    _ => null,
  };

  /// The logo for a harness id (`claude-code`, `acp:<cmd>`, …), or null when there is none.
  static Logo? harness(String id) => switch (id.replaceFirst(RegExp('^(acp|terminal):'), '')) {
    'everyai' => everyai,
    'claude-code' || 'claude' => const Logo._('claudecode-color'),
    'codex' => const Logo._('codex-color'),
    'opencode' => const Logo._('opencode'),
    'gemini' => const Logo._('geminicli-color'),
    'antigravity' || 'agy' => const Logo._('antigravity-color'),
    'github-copilot-cli' || 'copilot' => const Logo._('githubcopilot'),
    'kiro' || 'kiro-cli' => const Logo._('kiro-color'),
    'kimi' => const Logo._('kimi'),
    'qwen-code' || 'qwen' => const Logo._('qwen-color'),
    'cline' => const Logo._('cline'),
    'goose' => const Logo._('goose'),
    'mistral-vibe' || 'vibe-acp' => const Logo._('mistral-color'),
    'cursor' || 'cursor-agent' => const Logo._('cursor'),
    'grok' => const Logo._('grok'),
    'roo' || 'roo-code' => const Logo._('roocode'),
    'windsurf' => const Logo._('windsurf'),
    _ => null,
  };

  /// The logo for a desktop app's harness id or name (Claude, Cursor, Antigravity, Codex), or null.
  static Logo? app(String id) => switch (id) {
    'claude' || 'Claude' => const Logo._('claude-color'),
    'cursor' || 'Cursor' => const Logo._('cursor'),
    'antigravity' || 'Antigravity' => const Logo._('antigravity-color'),
    'codex' || 'codexApp' || 'Codex' => const Logo._('codex-color'),
    _ => null,
  };
}

/// A logo on a small rounded tile with a hairline, like an app icon: [logo] when there is one, else [letters] on
/// [color] (the old monogram).
class LogoTile extends StatelessWidget {
  const LogoTile({
    super.key,
    required this.logo,
    required this.letters,
    required this.color,
    this.size = 24,
    this.label,
  });

  final Logo? logo;
  final String letters;
  final Color color;
  final double size;

  /// What a screen reader says; the logo's own name when null.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final logo = this.logo;
    if (logo == null) {
      return Semantics(
        label: label,
        image: true,
        child: AgentGlyph(letters: letters, color: color, size: size),
      );
    }
    final theme = EveryTheme.of(context);
    final inner = size * (size < 20 ? 0.72 : 0.64);
    final Widget mark = logo == Logo.everyai
        ? BrandMark(size: inner)
        : SvgPicture.asset(
            logo.asset,
            width: inner,
            height: inner,
            colorFilter: logo.colored ? null : ColorFilter.mode(theme.text, BlendMode.srcIn),
          );
    return Semantics(
      label: label,
      image: true,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.isDark ? const Color(0xFF1E1E24) : const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(size * 0.28),
          border: Border.all(color: theme.border, width: size < 20 ? 0.5 : 1),
        ),
        child: ExcludeSemantics(child: mark),
      ),
    );
  }
}
