// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart' show TargetPlatform, immutable, visibleForTesting;

/// The systems a setup command is written for.
enum SetupOs {
  macos,
  linux,
  windows;

  /// The system the app runs on, or null where there is no terminal (phones, the web).
  static SetupOs? of(TargetPlatform platform) => switch (platform) {
    TargetPlatform.macOS => macos,
    TargetPlatform.linux => linux,
    TargetPlatform.windows => windows,
    _ => null,
  };
}

/// The system a shell in [env] runs: the host's own, or Linux inside any other environment (a WSL distro, a
/// container, a VM, an SSH remote). Null where the host has no terminal.
SetupOs? setupOsFor(bool isHost, TargetPlatform host) => isHost ? SetupOs.of(host) : SetupOs.linux;

/// The vendor's own way to install one coding CLI on one system, and its own sign-in. The app types [install] into a
/// terminal and never runs it: the user presses Enter, and any password is typed in that terminal.
@immutable
final class SetupCommands {
  const SetupCommands({required this.install, required this.login, required this.source, this.verified = false});

  /// One line for the system's shell. Windows lines are wrapped in `powershell -Command`, because our Windows
  /// terminal starts cmd.exe.
  final String install;

  /// The arguments of the CLI's own sign-in, run as `<program> <login>`. Empty: run the CLI itself and sign in there
  /// (usually `/login`).
  final List<String> login;

  /// The vendor page the line comes from.
  final String source;

  /// Whether [install] was checked against [source] (the page was read). Unchecked lines come from the hints this
  /// app had before and need the vendor's page read before they are trusted.
  final bool verified;
}

const _unixOs = [SetupOs.macos, SetupOs.linux];
const _anyOs = SetupOs.values;

/// A row for the systems in [os], all the same.
Map<SetupOs, SetupCommands> _row(Iterable<SetupOs> os, SetupCommands commands) => {for (final o in os) o: commands};

/// The setup lines by driver id (`driver_registry.dart`) and system. Only vendor URLs go in: nothing here installs
/// from a mirror or a package of ours. Every row says where it comes from.
final Map<String, Map<SetupOs, SetupCommands>> _table = {
  // https://code.claude.com/docs/en/setup (read 2026-11-05); `claude auth login` from `claude auth --help`.
  'claude-code': {
    ..._row(
      _unixOs,
      const SetupCommands(
        install: 'curl -fsSL https://claude.ai/install.sh | bash',
        login: ['auth', 'login'],
        source: 'https://code.claude.com/docs/en/setup',
        verified: true,
      ),
    ),
    SetupOs.windows: const SetupCommands(
      install: 'powershell -NoProfile -Command "irm https://claude.ai/install.ps1 | iex"',
      login: ['auth', 'login'],
      source: 'https://code.claude.com/docs/en/setup',
      verified: true,
    ),
  },
  // https://github.com/openai/codex (README, read 2026-11-05); `codex login` from `codex login --help`.
  'codex': {
    ..._row(
      _unixOs,
      const SetupCommands(
        install: 'curl -fsSL https://chatgpt.com/codex/install.sh | sh',
        login: ['login'],
        source: 'https://github.com/openai/codex',
        verified: true,
      ),
    ),
    SetupOs.windows: const SetupCommands(
      install:
          'powershell -NoProfile -ExecutionPolicy ByPass -Command "irm https://chatgpt.com/codex/install.ps1 | iex"',
      login: ['login'],
      source: 'https://github.com/openai/codex',
      verified: true,
    ),
  },
  // https://opencode.ai/docs/ (read 2026-11-05): curl for macOS and Linux (the brew formula is another major
  // version); on Windows the docs list choco, scoop and npm and recommend WSL. `opencode auth login` from
  // `opencode auth --help`.
  'opencode': {
    ..._row(
      _unixOs,
      const SetupCommands(
        install: 'curl -fsSL https://opencode.ai/install | bash',
        login: ['auth', 'login'],
        source: 'https://opencode.ai/docs/',
        verified: true,
      ),
    ),
    SetupOs.windows: const SetupCommands(
      install: 'npm install -g opencode-ai',
      login: ['auth', 'login'],
      source: 'https://opencode.ai/docs/',
      verified: true,
    ),
  },
  // https://cursor.com/docs/cli/installation (read 2026-11-05). The page names no sign-in; `login` is this app's
  // profile (acp/acp_agents.dart) and unchecked. The single quotes in the Windows line are for PowerShell.
  'cursor': {
    ..._row(
      _unixOs,
      const SetupCommands(
        install: 'curl https://cursor.com/install -fsS | bash',
        login: ['login'],
        source: 'https://cursor.com/docs/cli/installation',
        verified: true,
      ),
    ),
    SetupOs.windows: const SetupCommands(
      install: 'powershell -NoProfile -Command "irm \'https://cursor.com/install?win32=true\' | iex"',
      login: ['login'],
      source: 'https://cursor.com/docs/cli/installation',
      verified: true,
    ),
  },
  // The agents below keep the hints this app had; the vendor pages were not read again (unverified). npm lines are
  // the same on every system; the others have no Windows line until someone checks one.
  // https://antigravity.google/cli (the sign-in is `agy acp --login`, from the agent's profile).
  'antigravity': _row(
    _unixOs,
    const SetupCommands(
      install: 'curl -fsSL https://antigravity.google/cli/install.sh | bash',
      login: ['acp', '--login'],
      source: 'https://antigravity.google/cli',
    ),
  ),
  // https://github.com/google-gemini/gemini-cli
  'gemini': _row(
    _anyOs,
    const SetupCommands(
      install: 'npm i -g @google/gemini-cli',
      login: [],
      source: 'https://github.com/google-gemini/gemini-cli',
    ),
  ),
  // Not a coding CLI: the local model server behind Settings → Local models (no sign-in).
  // https://ollama.com/download/mac, /download/linux, /download/windows (read 2026-11-06).
  'ollama': {
    ..._row(
      _unixOs,
      const SetupCommands(
        install: 'curl -fsSL https://ollama.com/install.sh | sh',
        login: [],
        source: 'https://ollama.com/download',
        verified: true,
      ),
    ),
    SetupOs.windows: const SetupCommands(
      install: 'powershell -NoProfile -Command "irm https://ollama.com/install.ps1 | iex"',
      login: [],
      source: 'https://ollama.com/download/windows',
      verified: true,
    ),
  },
  // https://github.com/github/copilot-cli
  'github-copilot-cli': _row(
    _anyOs,
    const SetupCommands(
      install: 'npm i -g @github/copilot',
      login: [],
      source: 'https://github.com/github/copilot-cli',
    ),
  ),
  // https://kiro.dev/docs/cli/
  'kiro': _row(
    _unixOs,
    const SetupCommands(
      install: 'curl -fsSL https://cli.kiro.dev/install | bash',
      login: ['login'],
      source: 'https://kiro.dev/docs/cli/',
    ),
  ),
  // https://github.com/MoonshotAI/kimi-cli
  'kimi': _row(
    _unixOs,
    const SetupCommands(
      install: 'curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash',
      login: [],
      source: 'https://github.com/MoonshotAI/kimi-cli',
    ),
  ),
  // https://github.com/QwenLM/qwen-code
  'qwen-code': _row(
    _anyOs,
    const SetupCommands(
      install: 'npm i -g @qwen-code/qwen-code',
      login: [],
      source: 'https://github.com/QwenLM/qwen-code',
    ),
  ),
  // https://github.com/cline/cline
  'cline': _row(
    _anyOs,
    const SetupCommands(install: 'npm i -g cline', login: ['auth'], source: 'https://github.com/cline/cline'),
  ),
  // https://github.com/block/goose
  'goose': _row(
    _unixOs,
    const SetupCommands(
      install: 'brew install block-goose-cli',
      login: ['configure'],
      source: 'https://github.com/block/goose',
    ),
  ),
  // https://github.com/mistralai/mistral-vibe
  'mistral-vibe': _row(
    _unixOs,
    const SetupCommands(
      install: 'uv tool install mistral-vibe',
      login: ['--setup'],
      source: 'https://github.com/mistralai/mistral-vibe',
    ),
  ),
  // https://docs.augmentcode.com/cli/overview
  'auggie': _row(
    _anyOs,
    const SetupCommands(
      install: 'npm i -g @augmentcode/auggie',
      login: ['login'],
      source: 'https://docs.augmentcode.com/cli/overview',
    ),
  ),
  // https://docs.factory.ai/cli/getting-started/quickstart
  'factory-droid': _row(
    _anyOs,
    const SetupCommands(
      install: 'npm i -g droid',
      login: [],
      source: 'https://docs.factory.ai/cli/getting-started/quickstart',
    ),
  ),
  // https://x.ai/news/grok-build-cli
  'grok': _row(
    _unixOs,
    const SetupCommands(
      install: 'curl -fsSL https://x.ai/cli/install.sh | bash',
      login: ['login'],
      source: 'https://x.ai/news/grok-build-cli',
    ),
  ),
};

/// The setup lines for [driverId] on [os], or null when there are none (the own harness, an agent added by hand, or a
/// system the vendor has no line for).
SetupCommands? setupCommandsFor(String driverId, SetupOs os) => _table[driverId]?[os];

/// The ids that have a row, for tests.
@visibleForTesting
Iterable<String> get setupDriverIds => _table.keys;
