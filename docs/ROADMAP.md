# EveryAI roadmap

Status as of 2026-11-07: alpha `0.1.0-alpha.6` (signed: notarized macOS DMG, Microsoft Store, GPG-signed Linux packages; the apps update themselves; a web app at https://app.everyai.dev). macOS is the daily driver; Windows and Linux
build in CI but haven't been tested on real machines. The Code workspace's internals are in
[CODE_ROADMAP.md](CODE_ROADMAP.md).

## 1. Positioning

**EveryAI is a coding harness and orchestrator for every coding agent.** Native agents like Claude Code, Codex and
OpenCode are already good, and millions of people use them. EveryAI doesn't replace them; it gives them one workspace
and adds what they don't have:

1. **The harness and orchestrator are the product.** Our own agent (the EveryAI harness) runs any model, and our
   workflows, checks, rewind and tools run in every agent. Model access (OpenRouter or Anthropic) is plumbing, not the
   product.
2. **BYOK.** Users bring their own API keys and their own subscriptions. EveryAI holds no provider keys in the dev
   build and spends nothing on sessions it doesn't lead.
3. **Local AI.** Models on the user's computer (Apple's on-device model, Ollama, LM Studio, llama.cpp, Jan, vLLM, MLX)
   run Chat and the EveryAI harness. A bundled copy of the backend runs chats on them, and on the user's own keys, on
   the computer itself; small models get a lighter harness profile.
4. **What exists works.** Chat with artifacts, Code with approvals, worktrees and checkpoints, remote control, skills
   and MCP are built and run on macOS (pre-alpha:
   expect bugs).
5. **Magical integration.** Outside agents feel native (their slash commands, modes and tool names), sessions resume
   across agents, a usage limit hands off without losing a step, and one-step setup brings in agents the user already
   has.

## 2. What is built

- **Every agent in one workspace:** drivers for Claude Code, Codex, OpenCode, ACP agents (Antigravity, Gemini CLI,
  Cursor, Copilot, Qwen Code, Kiro, Kimi, Cline, goose, Mistral Vibe, Auggie, Factory Droid, Grok, any ACP agent) and
  terminal-only CLIs; installed-agent detection and "Add agent" from the ACP registry.
- **Native feel:** each agent's own slash commands and modes, its own words in the transcript, our safety floor as
  advice for outside agents (a hard floor for the EveryAI harness).
- **Increments for every agent, at no cost to us:** a local MCP host with `check`, `bug_check`, `diff_stats`,
  `goal_check`, `run_script`, memory and saved plans; checkpoints and rewind; workflows (Ultra, Bug fix, Security
  review) as `workflow.js` run in Deno and served as MCP prompts; Max as an approach skill with fork tools.
- **Continuity:** handoff on a usage limit (native import into the next agent's session format, or facts plus the
  transcript file), a default handoff target, and resuming any agent's earlier session from New session.
- **One EveryAI design** on every OS (dark, light, Pure black). The Code session has a five-tab panel (Session, Diff,
  Preview, Files, Processes), a terminal drawer with tabs and a git button that follows the repo; the Board shows
  every session in Needs you, Running and Done columns, with approvals and questions answered on the card.
- **Seeing and testing what's built:** a live Preview shared by the user and the agent (take over, give back), and
  the `app` tool for web and Electron pages, Flutter and React Native apps, the iOS Simulator, the Android emulator
  and desktop windows. Every process, Docker containers included, opens in a terminal.
- **Local models:** servers found on the computer, one-click packs sized to its hardware, Apple's model as the macOS
  chat default, and chats on local models and own keys run by a backend bundled in the app.
- **A cheaper execution loop:** runtime profiles, checks after each turn on the changed files, plan batches with a
  check each, and no AI credit in commits for any harness.
- **The EveryAI harness:** any model on the user's key or a local model, per-family tools, approvals, compaction,
  forks in worktrees, and the shared browser and `app` tool for checking its own work.
- **Chat:** modes (Chat, Search, Research, Learn, Summarise), artifacts with versions and downloads, slides, charts,
  diagrams, quizzes, memory and history on the device.
- **Remote control:** phones, tablets and the web app pair with the desktop over an end-to-end encrypted relay.
- **Infrastructure:** the dev backend on Anole 0.5.1 with its own TLS and rate limiting; Windows and Linux builds from
  CI; a first-launch tour.

## 3. What's next

In order:

1. **Live testing:** a real turn through every outside driver, handoff and resume, workflows on outside agents, local
   models on a real server, the `app` tool on real projects, and Windows and Linux on real machines.
2. **Distribution:** the backend on its own domain with real sign-in, a `curl` installer and apt/dnf repos served
   from Cloudflare R2, then Android (Google Play and a signed APK) and iOS (TestFlight, then the App Store). No Mac
   App Store: its sandbox would break the agents, terminals and project access.
3. **The standalone package:** the same MCP server, skills and workflows as a plugin for Claude Code, Codex and
   OpenCode in the user's own terminal.
4. **Lead Mode:** the EveryAI harness leads and delegates batches of work to other agents, each in its own worktree,
   with a check gating every merge.
5. **Live terminal views:** each agent's real terminal UI beside the transcript where it can attach.

Also planned: an OS sandbox for shell commands (Seatbelt, bubblewrap), headless mode (`everyai serve`) and user
hooks, LSP diagnostics, local models for outside harnesses, and the live views on the phone and web.

## 4. Risks

- **Vendor terms.** Running a user's own logged-in CLI is allowed for some vendors and unclear for others. Claude Code
  and Google's agents sit behind a consent setting until their terms are checked, and EveryAI never reuses an agent's
  login tokens.
- **Moving targets.** Each agent's protocol and session format can change with any release. Drivers are pinned to
  profiles and tested against recorded fixtures, but they need upkeep.
- **Verification debt.** Much of the multi-agent work passed analyze and unit tests but hasn't run end to end against
  every real agent.
- **The agent runs as the user.** Approvals and the safety floor are defence in depth over shell strings, not a
  sandbox, until the OS sandbox lands.
- **Six platforms, one small team.** One design now covers every platform, but the test surface is still six
  platforms; Windows and Linux haven't been tested on real machines.
