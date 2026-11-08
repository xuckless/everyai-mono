# Changelog

EveryAI is in alpha. Signed releases start at `0.1.0-alpha.1`; the earlier unsigned dev build was
`0.1.0-dev-nonsigned`. Earlier changes are listed by date and pull request.

## 0.1.0-alpha.7 (2026-11-08): no account needed, and a browser you can sign in to

### No account needed
- **Signed out is a normal state.** Chat, Code, local models and your own keys work without an account; nothing
  asks you to sign in.
- **Sign in by email link** when you want one: a link that signs in the device that asked, or a 6-digit code.
  Passwords and Google sign-in are gone.
- **Remote control without an account.** Pair a phone, tablet or the web app by QR code; the pairing is the
  identity. Signing in later moves your computer and its devices to your account. The relay only passes
  end-to-end encrypted frames; when it is busy a device waits in line, and it says so when a limit is reached.
- **Your keys stay on your computer.** Own keys go only to the server inside the app, never to EveryAI's hosted
  server, which refuses them. OpenRouter and Anthropic are connected today; other providers can be saved and
  are checked before they're offered.
- **No credits or plans.** EveryAI runs on your own keys, your subscriptions and local models. Billing, plans,
  the wallet and top-ups are gone from the app. Usage and spend caps stay.
- The dev server moved to `https://api.everyai.dev`.

### A browser you can sign in to
- **Each Code session has its own sign-ins** in the Preview browser: its cookies and site storage are kept
  (sealed, with the key in your keychain) and restored next time. Save a login for a project or for every project.
- **Login wall:** when the agent reaches a sign-in page, it waits and offers Take control, Use saved login, Sign in
  in a window, or Skip.
- **A browser for people too:** tabs and pop-ups, page dialogs, file pickers, downloads, a right-click menu with
  "Ask the agent about this", Find, and the usual shortcuts. Keys type what you press, AltGr included.
- A dialog in one tab no longer stalls actions on another tab of the same site for 30 s.

### Agents
- **Auto mode** on every lead that supports one: Full auto on the EveryAI harness, Claude Code's own auto mode
  behind EveryAI's checks, Codex's auto reviewer.
- **Git buttons ask the agent:** Commit, Create PR and Merge locally send the session's agent a request (queued
  while it works).
- **Language servers:** a `diagnostics` tool, and a hint when an edit adds errors. **Notebooks:** cells are read and
  edited by id.
- **Pause all** next to Stop all: the lead, its forks and its workflows pause between steps, and Resume picks up.
- **Workflows ask first:** a run starts from a card with its estimate (Start, Adjust, Cancel), pauses past it, tells
  the lead when an agent stalls, and checks it is still on track at each phase.
- `/usage` works on every lead, with plan limits as bars.
- Claude Code: a message sent while Claude wakes for a background report waits its turn, and Stop then stops it.

### Figures and slides in Chat
- **Figures by id:** SVGs, charts and diagrams are versioned and can be edited, checked by eye (`look`), and placed
  in documents and slides. Slides take free layouts, and PowerPoint gets real shapes and text.
- Point at a part of a figure to ask about it; edit its colours and text by hand.

### Local models
- **Local servers you can start and stop.** Settings → Local models shows each server's state (Starting, Running
  and who started it, Stopping, Stopped, or why it failed) with Start and Stop: Ollama, LM Studio (`lms`), Apple's
  model, and a server added by URL with its own start command. A server started outside EveryAI can be stopped
  too, after a confirm. Each model on Ollama and LM Studio shows whether it's loaded, with Load and Unload.
- **Nothing left behind at quit.** EveryAI unloads every model it loaded (Chat and Code, on any server) and stops
  the servers it started; servers you started keep running. The built-in server ends by itself if the app is
  gone, and can no longer be started again while the app quits.
- **Apple's model works.** It answers without tools (its server refuses most of our tool schemas, and its window
  is small); Private Cloud Compute is no longer offered (Apple allows it only in Terminal).
- **New chats start on the model you last picked.** Apple's model is the default only until you pick one.

### Install
- **One-line installs** from `get.everyai.dev`: `curl -fsSL https://get.everyai.dev/install.sh | sh` on macOS and
  Linux (signature and checksum checked), and `irm https://get.everyai.dev/install.ps1 | iex` on Windows (the
  Microsoft Store through winget).

### A steadier app
- The macOS menu bar is mounted once; the "menu delegate" error in debug builds is gone, and the server banner no
  longer rebuilds the page.
- Language servers, MCP servers and headless Chrome processes don't outlive their session or the app; pictures no
  longer pile up in memory over a long session.

## 0.1.0-alpha.6 (2026-11-07): the lead stays free, and a steadier app

### Sessions that keep talking
- **Forks always run in the background.** The lead stays free to chat while its forks work; each report arrives
  when it's done, the same as with workflows.
- **Send now** on a queued message interrupts the agent and sends it (or just sends it when nothing runs).
- **Stop all** beside Send and on Board cards stops the lead's turn, its background forks and its workflows at once,
  and nothing wakes the lead afterwards.
- **Take-control reminder:** when an agent step waits on a browser, simulator or window you took over in Preview, the
  chat says so, with Allow to hand it back.
- Claude Code: after an interrupt, the stopped turn's late result no longer marks the session paused.

### Board and Processes
- **Work inside a session** folds into one line on its card (workflow runs, forks, background commands) and opens by
  itself when a child waits on you. Questions are answered right on the card.
- A session running a workflow stays under **Running**, or **Needs you** when one of its agents asks; a failed session
  isn't hidden behind its workflow.
- A fork's loop-guard and bug questions go to its lead; you see only approvals and decisions.
- **Processes:** finished shells and commands go into one foldable **Done** list, with when they ended.

### Approvals
- In a workflow, **Allow all commands** on one agent's card covers its read-only siblings too, without loosening the
  lead's own approvals. It now also covers chained commands and `$(…)`; risky commands still ask.
- Read-only workflow agents of a lead in Full auto or Bypass run commands without asking, and still ask before edits.

### Security
- A repository whose git config names a filter, hook or merge driver with "=" in it can no longer slip past EveryAI's
  git guard; EveryAI's git calls stop there until it's removed.
- Only the desktop itself (its host token) pairs devices, removes itself, and adds or deletes its webhooks; a device
  can unpair itself. Host control frames are size- and rate-limited.

### A steadier app
- Lifecycles across the app (Code session connection, Preview, onboarding's key check, updates, remote hosting,
  settings writes and more) are explicit states now: late answers are dropped, and double clicks run once.
- Stop while a chat turn is starting keeps your message and ends as a stopped answer you can retry; Stop then a
  quick send runs one turn.
- `everyai://prompt` links fill the new chat again.
- The `app` tool's `android` and `ios` sources drive a running device the session didn't start.
- Chat sources show each site's favicon (through DuckDuckGo's icon service, so the sites aren't contacted), and a
  drag on the sources row no longer breaks text selection.

## 0.1.0-alpha.5 (2026-11-07): a new look, local models, and tools to test your app

### A new look
- **One EveryAI design on every OS.** New colours, type (Geist), icons (Lucide) and motion, with dark, light and
  Pure black themes picked from pictures. The design-language picker is gone.
- **Shell and sidebar:** an inset content panel, a Chat | Code switch, project groups that fold, and harness logos with
  a status dot on every session.
- **Code session:** a five-tab panel (Session, Diff, Preview, Files, Processes), a terminal drawer with tabs, a calmer
  New session page, and a Terminal button on Code home.
- **Board:** Needs you, Running and Done columns. Approve, deny and answer questions on the card; cards glide between
  columns; columns resize; Done cards clear.
- **Settings** opens as a window over the app, with grouped sections that fold and pages laid out on cards.
- **Windows and Linux** draw their own title bar, with room to drag the window.
- The app reopens where you left it. The terminal draws Powerline and Nerd Font prompts.
- **What's new** shows once after an update; Settings → About opens it again. The intro no longer
  comes back after updates.

### Local models
- **Models on your computer.** EveryAI finds Ollama, LM Studio, llama.cpp, Jan, vLLM and MLX servers, and Apple's
  on-device model through `fm serve` (after you agree to Apple's terms once in EveryAI's terminal). Add any other
  server by its URL.
- **One-click packs.** Settings → Local models reads your RAM, GPU memory and free disk and offers Light, Balanced and
  Best packs (a chat and a coding model), greyed out when they won't fit. Ollama downloads them in the background;
  without Ollama, its official installer is typed into EveryAI's terminal for you.
- **Chat runs where the model is.** A copy of the EveryAI server ships in the app and runs chats on local models and
  on your own keys on your computer, so your keys no longer pass through our server. Web search works without a key.
- **Apple's model is the default chat model on macOS** when it's there. With no key and no local model, Chat says
  what to set up instead of failing.
- **Code on local models.** The EveryAI harness calls the local server directly; small models get a lighter set of
  tools and rules. Outside agents keep working with no key and no model.

### Tools to see and test what you build
- **Every process opens in a terminal.** Click a shell, server or Docker/Podman container in the Processes tab to
  see its whole log and type into it. Background shells run in a real terminal, and agents can send them input.
- **A live Preview.** The agent and the Preview share one Chrome per project. Watch the agent work with a ghost
  cursor, take control and give it back.
- **The `app` tool** lets every agent see and operate the app it builds: web and Electron pages, Flutter and React
  Native apps, the iOS Simulator, the Android emulator, and desktop windows (macOS, with Windows and Linux in early
  shape). It takes screenshots, lists elements, clicks, types, and reads logs.
- **Guarded input:** real clicks and keys only reach the app's own window, never with secure input on, never into
  password fields, and wait while you're using the mouse or keyboard. Real input on macOS needs a one-time consent
  (Settings → Code → Driving apps).

## 0.1.0-alpha.4 (2026-11-06): a cheaper execution loop, and no AI credit in commits

- **Runtime profiles.** Commands that take 3 s or more are timed on every harness (approval waits left out) and kept
  per project. Every lead, EveryAI's own included, sees the slow ones in its briefing, marked as recorded data.
  Commands with secrets are never kept, and a profiles file a repository ships is ignored.
- **Checks after each turn.** Format, lint and type checks run on the files the agent changed in that turn (Dart,
  JS/TS, Python, Go, Rust), in every mode but Plan, with no approval card. The safety floor and your deny rules still
  apply. They download nothing, slow project-wide checks never hold up your next message, and new errors in other
  files are counted. The report goes with the next message.
- **Plan batches.** A plan can split work into batches, each with a check. In Ultra each batch is one agent, and its
  check decides whether the work merges back. A batch with no test merges as "unverified". The `check` tool takes a
  scope (changed, files, a test name or the full suite).
- **No AI credit in commits or PRs**, for every harness: Claude Code and Codex are told so through their own
  per-session settings, the others through the briefing, and commits EveryAI makes itself are scrubbed.
- **Workflow results keep the workers' commits.** "Commit here" and "New branch" bring each worker's commits over,
  with their messages and authors, then one commit for the rest. GPG signing is honoured and your own staged changes
  stay as they were.
- **Thorough** checks each part once, not every edit.

## 0.1.0-alpha.3 (2026-11-05): security in the tools, Bypass, environments, Windows

- **Security lives in the tools.** Every tool guards itself and never adds an approval card, in every mode and for
  every lead:
  - Web pages, search results, browser pages and outside files reach the model marked as data, with hidden
    characters removed.
  - Reading credential stores and sending data out (uploads, gists, pushes to new remotes, paste and webhook sites)
    are refused, and secrets are hidden in tool output.
  - Look-alike and typo domains of official sites are refused. Package installs are checked for typosquats and
    names that don't exist.
  - The browser never types into password or payment fields, and screenshots skip password managers.
  - EveryAI's own git calls never run a repo's hooks. MCP tool lists are pinned at consent, and skills, agents and
    commands are scanned for hidden instructions.
  - A `security_alert` tool shows a red card and a notification when content tries something harmful.
  - Chat gets the same web guardrails, the alert card, and a warning on links that carry data.
- **Permissions:**
  - **Bypass EveryAI checks:** a switch under the modes that turns off EveryAI's floor, rules and risk prompts for
    every agent in the session. Outside agents keep their own permissions.
  - **Full auto never asks,** edits outside the project included.
  - **Approvals ask once and are kept:** Allow saves the rule for the project. "Just this once" is still there.
- **Bypass permissions:** a new mode, after Full auto, that turns every EveryAI check off (safety floor, deny rules,
  risk prompts, the window question for screenshots). It asks you to confirm before it turns on, and forks,
  subagents and workflow agents inherit it.
- **Fewer approvals on long runs:** "Allow similar for this session" now works for chained commands
  (`cd app && npm test | tail`), one rule per part. A new "Allow all commands / all edits in the project / all MCP
  tools for this session" covers the whole kind; the floor and risky actions still ask. Allow rules match a chain
  when every part is allowed. Rules changed in Settings apply to the running session at once, including a card
  already waiting.
- **MCP tools are checked before the agent sees them:** the EveryAI harness keeps each server's tools as they were at
  its first session. A tool that changes later, or whose description or parameters carry hidden characters,
  instructions to keep things from you, reach for secrets or talk about other tools, is left out until you review it
  in Settings → MCP servers ("Review tools…"). On the first session after this update, flagged tools of servers you
  already use are left out once. The review shows each tool's description and parameters in full. Two servers that
  offer the same tool name both get a `<server>__` prefix, and the newcomer is held for review. What MCP tools return
  is marked as outside data. Gaps: Claude Code, Codex and OpenCode load their own MCP servers, which EveryAI doesn't
  see. ACP agents (Gemini and others) connect to whole servers, so a server with any tool waiting for review is left
  out of their sessions entirely, and only EveryAI sessions check tools: a server never used in one goes to ACP agents
  unchecked, and a change shows up only after an EveryAI session connects to it again.
- **Agents in other environments:** projects can run inside WSL, Docker or dev containers, Lima, OrbStack,
  Multipass or Colima (project ⋯ menu → Environment). SSH remotes can be added; agents don't run there yet.
- **Windows:** the EveryAI harness uses Git Bash; Stop ends the whole process tree; terminal agents run through
  ConPTY; pasted clipboard images work (thanks to TiaoTiaoLin).
- **Setup:** each harness shows Ready, Sign in or Set up, with a one-step install in the terminal, and a checklist
  to import MCP servers, rules, commands, agents and skills from other tools.
- **Automations:** scheduled tasks and signed webhooks start ordinary Code sessions.
- **Small things:** pastes over 32 KiB become attachments; `everyai://prompt` links fill the composer.

## 0.1.0-alpha.2 (2026-11-05): updates in the app, and the prober fixes

- **Updates without reinstalling.** Each launch checks GitHub Releases (Settings → About: Check now, and "Get
  pre-releases"). The macOS release downloads the update quietly through Sparkle and shows "Restart to update" in the
  sidebar. A Linux AppImage downloads the new AppImage, checks it against the signed `SHA256SUMS` and replaces itself.
  The .deb offers the download. Microsoft Store installs keep updating through the Store. This release is the first
  that can update itself; from 0.1.0-alpha.1, install it once by hand.
- **Workflows:** workflow agents get proof tools (`bug_check`, `check`, `diff_stats`, `report_issue`). Bug fix
  reproduces and verifies through `bug_check` and asks for the bug, steps and expected result when the report is
  thin. Ultra runs research → implement → review → refix for each item and loads only the plan it wrote or the one
  you picked. Results read verdict first (status, cost, agents, time) with the raw JSON folded under Details. The same
  finding from several review lenses is merged. Finished work asks: Commit here, New branch or Leave uncommitted.
  Finished runs can be dismissed.
- **Outside leads (Claude Code and others):** `screenshot`, `browser` and `app_run` through EveryAI's MCP tools. The
  session's own apps are free; other windows ask once. Fork reports and workflow results arrive as signed
  `<everyai-notice>` blocks, never as plain user messages. Claude Code skills can be turned off per project.
- **Approvals:** every card and refusal says why it asked (the rule, the mode or the safety floor). Writes to the
  project's scratch folder and the temp folder don't ask (except in Plan). "Allow for all forks" covers sibling forks.
  Forks, subagents and workflow agents start in the parent's mode, Full auto and Claude Code's native auto included.
- **Sessions:** `/usage` shows plan windows and Claude Code's own report; Running work groups fold; subagent chats
  say plainly they aren't the main chat; the right panel sits beside the transcript whenever both fit.
- **Layout:** every screen starts below the top bar; rows of text and buttons wrap instead of overflowing; short
  windows scroll instead of cutting off. New layout tests cover every screen and card in all four design languages.

## 0.1.0-alpha.1 (2026-11-05): the first signed release

- **macOS:** a Developer ID signed, notarized and stapled DMG on
  [GitHub Releases](https://github.com/xuckless/everyai-mono/releases), also through Homebrew
  (`brew trust xuckless/tap && brew install --cask xuckless/tap/everyai`).
- **Windows:** the [Microsoft Store](https://apps.microsoft.com/detail/9PHCKCV3J9S9) (the Store signs the MSIX), or
  `winget install --source msstore 9PHCKCV3J9S9`.
- **Linux:** an AppImage and a .deb with GPG signatures and `SHA256SUMS` on GitHub Releases
  (key: `packaging/linux/everyai-release-key.asc`).
- A [privacy policy](PRIVACY.md) for the store listings. The first-launch tour shows again for the new version.

## 2026-11-05: the console layout (PR #8)

- **Session screen:** a title menu, icons for Session info, Diff and Files that switch one resizable right panel, and
  a git button that follows the repo (Commit → Create PR → View PR → Merge locally). Session info shows the
  environment, context (outside agents: what they report, the rest "not itemised"), usage and limits, running work
  (click a row to open that chat in the panel) and changes. Files has light editing (saved after a checkpoint, so
  rewind still works). Terminal, Processes and Preview move to a bottom drawer (⌃`).
- **Composer:** a strip with the agent (switch or hand off), Workflows, Skills and MCP; model · effort · workflow ·
  mode as quiet text under the box; a limit banner with the numbers an agent reports.
- **Sidebar:** Pinned and Recents with status icons.
- **Briefing:** every agent is told to prefer EveryAI's tools where they fit. An agent that hits a problem with one
  of them may draft a GitHub issue, but posts only after the user says yes (`gh issue` commands always ask); a
  `report_issue` tool builds a prefilled link with paths stripped.

## 2026-11-04: every coding agent, one workspace (PRs #1–#7)

The Code workspace now runs outside coding agents as well as the EveryAI harness.

- **#1 Outside agents as the lead of a Code session.** Drivers for Claude Code (stream-json), Codex (app-server),
  OpenCode (`opencode serve`), ACP agents (Gemini CLI and others) and terminal-only CLIs. A loopback MCP server gives
  every session EveryAI's tools, with a per-session token. A silent briefing tells each agent what EveryAI provides.
  Claude Code and Gemini sit behind a consent setting.
- **#2 Switching the lead, with a no-spend handoff.** A session can change agents mid-way. The handoff carries
  deterministic facts (plan, todos, touched files, git state) plus the whole conversation as a file, and the new lead
  finishes a turn the usage limit cut off. EveryAI makes no model call for it.
- **#3 0.1.0-dev-nonsigned.** The dev deployment (Anole 0.5.1 with its own TLS and rate limiting, BYOK only, no
  sign-in), the app waiting for the server to wake, `scripts/launch.sh`, Windows and Linux builds from CI, and the
  first-launch tour with the Dev Build Terms.
- **#4 More agents over ACP and installed-agent detection.** Antigravity, Copilot, Kiro, Kimi, Qwen Code, Cline,
  goose, Mistral Vibe, Auggie, Factory Droid, Cursor and Grok, each with a pinned profile; the app finds which are
  installed.
- **#5 Handoff, native parity and workflows.** Native session import (the conversation written into the next agent's
  own format and resumed); "Your limit ran out, switch to:" with a default handoff; each agent's own slash commands,
  modes and tool names; the safety floor as advice for outside agents; Ultra, Bug fix and Security review as
  `workflow.js` files run in Deno and served as MCP prompts; Max as a skill plus fork tools; checks, rewind and
  `run_script` for every agent; "Add agent" from the ACP registry.
- **#6 Resume any agent's earlier session.** Pick a folder on New session and the list shows earlier sessions from
  Claude Code, Codex, OpenCode and Gemini CLI, with their full history; picking one resumes it on its own agent.
- **#7 The work box** (by Wendy Nguyen). Each turn's thinking, narration and tool steps fold into one box, and the
  final answer stays outside it.

## 2026-10-30 → 2026-10-31

175 commits since the last README, by area. The highlights:
- **The EveryAI harness** replaces OpenHands for new Code sessions: any model, per-family tools, tiers up to Max/Ultra with enforced phases, forks in worktrees run by an orchestrator, Bug fix mode, retries, per-call approvals, gentler compaction, write-in-parts, and a browser and screenshots for checking its own work.
- **Chat modes** Learn, Summarise, Search and Research (our own multi-model research harness), charts inside documents, images, Excalidraw, Polish for figures, memory and chat search.
- **Remote control** from phones, tablets and the web; **BYOK** for OpenRouter and Anthropic; a searchable **Settings** modal; **MCP**, **skills**, **agents** and **slash commands**.
- **Backend** hardening from the Anole docs audit, and the **FSL-1.1-ALv2** licence.

<details>
<summary><b>🛠️ EveryAI harness: the agent loop</b> (32)</summary>

- `870cf22` Add the EveryAI harness: an agent loop in the app beside OpenHands
- `9a7555d` Add a live check that drives the EveryAI harness on a real model
- `4df6519` Fork subagents and compact in place on the EveryAI harness
- `9845133` Judge /goal with the session's own model on the EveryAI harness
- `03aefaf` Export a Code session as Markdown and add the browser OS harness check
- `a13d088` Add a Tasks pane listing a session's subagents, forks and background commands
- `bf357e3` Serve the EveryAI harness to paired devices over the agent-server protocol
- `9fde0b9` Compact EveryAI sessions in place with /compact
- `891fe3e` Let a library agent run a Code session as its main agent
- `cde9bfc` Run EveryAI subagents in the background on request
- `c0d0e20` Record cached prompt tokens and add a live fork cache check
- `135dd4a` Let EveryAI agents look at images they read
- `bced7af` Connect EveryAI sessions to the project's MCP servers
- `74afddd` Tell EveryAI agents they can look at what they build, and check it live
- `79c25a1` Add an efficiency-to-quality work style for Code sessions
- `3216a87` Give each EveryAI fork its own worktree and merge it back when done
- `709f635` Add a live check of a fork editing its worktree and merging back
- `90ed7ff` Keep an EveryAI reply's text between its tool calls, and stream tool progress
- `4841275` Ask EveryAI agents to work in visible steps and to wait for dependent results
- `8413e77` Wake an EveryAI agent that sleeps to wait for its forks; check UIs through real clicks
- `c4f5b9f` Stub out harness switching: new sessions run on EveryAI, and OpenHands starts only when an old session needs it
- `a467ca6` Keep a session off the files its subagents are changing
- `cc6467f` Run each web search once per session
- `6a856c0` Code: retry model calls on transient errors
- `0ef3ad0` Code: answer each pending call on its own; run more reads in parallel
- `e6a18f3` Code: clear old tool output before summarizing; carry the working state over a compaction
- `0fc7f33` Code: tools and rules per model family; apply_patch for GPT models
- `39b53c2` Code: fixes from the Gemini Flash and Kimi K2.6 Max runs
- `4792bdf` Code: build big files in parts with write mode append
- `bf5d5ce` Code: a browser and window screenshots for the agent, and a debugging routine
- `6d553c4` Code: Option-Enter sends now again; shortcut hints drawn as text
- `644f490` Tests: the approval card's Allow all label comes from Host.enterKeys

</details>
<details>
<summary><b>🧭 Tiers, forks and orchestration (Max, Ultra, Bug fix)</b> (15)</summary>

- `2c3010d` Let the Code agent hand work to subagents that run as their own conversations
- `08e9b59` Add an agent library that subagents can be started with
- `51ec34c` Add the Ultra engine: a planned multi-agent run with caps and a journal
- `76f268f` Add the Ultra toggle, caps and a live progress tree to Code sessions
- `5d09d58` Hold Code budgets in the background and stop Ultra steps' leftover processes
- `35c64bf` Count all of an Ultra run's spend against its cap
- `1901c77` Make library agents roles that forks take, each on a model the user picks
- `bcaf9e0` Run Max sessions as a research → questions → plan → build → verify flow the harness enforces
- `62a3bec` Replace Ultra with a tier: Max's flow, with research run as a workflow the session sizes
- `d9b225d` Let the orchestrator pick each child's model from the user's models
- `715eb52` Add Bug fix mode: reproduce, triage, research when hard, plan, fix, verify, with the harness checking each step
- `903c745` Max in Full auto: approve the plan inside the held call, so the plan gate opens
- `ded7c3a` Show Max/Ultra progress only in the phase strip; result files on devices
- `302e85c` Code: the orchestrator runs its forks: their questions, check-ins, stops and integration
- `7604ce6` Put a tier bar in the Code agent menu and slim the session top bar

</details>
<details>
<summary><b>🔒 Code safety and permissions</b> (11)</summary>

- `7d2c7f9` Decide every Code action in the app, with a safety floor that holds even in Full auto
- `0370141` Keep web_fetch away from local and private networks
- `e66b8e9` Make Stop end every process a Code session left running
- `373dc3d` Pause and ask when the agent repeats the same step, and keep huge tool output out of the transcript
- `046a6cb` Close gaps in the command checks that let writes and wipes through
- `4794609` Keep a cloned repository from approving its own commands or reading files outside it
- `f0642ed` Make Stop leave the user's own tmux panes alone
- `345a9e9` Ask before editing outside the project in Full auto; keep agent scratch out of git
- `11cb3f6` Sandbox research jobs and send every Code web fetch through the safe fetcher
- `d6f7637` Ask before running commands that came with a project, remember the window size, and add a Projects page
- `5062ccc` Show the whole text of a project command, agent or skill before trusting it

</details>
<details>
<summary><b>📋 Code workspace UI</b> (23)</summary>

- `4a7e373` Keep Changes and the usage meter current while the agent works
- `4231e62` Answer question cards and plans inside the tool call so the agent keeps its turn
- `5504d34` Load the project's AGENTS.md files into Code sessions ourselves
- `797ab6b` Compact a Code session into a summary and a fresh conversation
- `d2081ad` Stop telling the Code agent that long tool output is cut for it
- `f43f7c1` Switch the Code agent's model and effort from one menu, live
- `3b63cf2` Keep Code sessions going through key refusals and sidecar crashes, and bundle the agent server
- `ac32608` Add a Code top bar with layered settings and system prompts
- `a16e08c` Add Terminal, Processes and Preview panes beside Code sessions
- `86be6f3` Show the files an agent finished with, and notify when a session needs you
- `99b1168` Rewind a Code session's conversation along with its files
- `3340346` Start Code sessions in repositories that have no commits yet
- `f6b3839` Let the Code session title flex, key transcript rows and link edits to Changes
- `3318db3` Work in place by default, with Changes against the session's starting snapshot, and give Settings one shell
- `b8ce3c6` Let Code rows shrink instead of overflowing on narrow windows
- `d1d926a` Finish worktree sessions from Changes: push, open, and remove after merge
- `5f107fc` Set a spending cap when starting a Code session
- `31595e2` Show the EveryAI mark for the agent's thoughts instead of a generic sparkle
- `1a62665` Remove projects from the Code project picker
- `47ca446` Don't treat a home-folder dotfiles repo as a project's repository
- `b122e6e` Bring the session's controls to the New session page; scroll the settings popover
- `3b052b1` Show Changes for in-place sessions in a repository with no commit yet
- `654a628` Show the agent's task list only above the composer

</details>
<details>
<summary><b>🔌 MCP, skills, agents and slash commands</b> (14)</summary>

- `7ccf4db` Let Code sessions use MCP servers set up in Settings
- `4e511e7` Note why mcp_config is a flat map of servers
- `f419963` Open a command menu when a message starts with a slash
- `3c65685` Run saved prompts as custom slash commands from Markdown files
- `9ae7f25` Let a chat request force the first tool call, and draft skills from a conversation
- `1b50253` Add the chat slash commands: model, effort, new, retry, make commands, export and learn
- `01d72d0` Let Code sessions use Agent Skills, with import and a trust gate
- `ba31c1b` Add the Code session commands: plan, build, model, effort, clear, compact, rewind, stop, cost and btw
- `4d56d52` Let Chat use the user's skills, loaded on demand
- `0973af3` Ship four built-in skills that steer slides, documents, diagrams and vector art
- `85eb184` Add the Code commands review, goal, commit, pr, learn and morning
- `c566f64` Keep project commands in their project and rank exact command names first
- `53effff` Harden skill imports, project skill trust and bundled skill updates
- `5d81fa6` Resolve /learn ./ and ../ paths against the session's folder

</details>
<details>
<summary><b>💬 Chat: tools, modes, search and research</b> (16)</summary>

- `5ff6942` Let chat turns wait for tools the app runs itself
- `b765d47` Recover from replies cut off by the output limit instead of stalling
- `c921dc2` Count DeepSeek cache hits as cached tokens
- `894ec15` Let chat answers search the web, number every source once, and read long pages in windows
- `519a93f` Let chat answers ask the user multiple-choice questions in a card
- `8cacb80` Keep reasoning across tool steps and let chats pick a thinking effort
- `3a08c8c` Keep local memory notes and let chats search earlier chats on the device
- `f647a0a` Route side jobs to cheap models and keep follow-ups in the user's language
- `c247d23` Wire memory and chat search into the chat turn
- `d3ffbc3` Keep memory out of system authority and in step with what the user keeps
- `735ef14` Add a thinking-effort menu to the chat composer, kept per conversation
- `3a5cbac` Ask Anthropic models for a forced tool in words when thinking is on
- `d35d61b` Question cards: mark the agent's recommended option
- `45c630d` Chat modes: Learn and Summarise, mode blocks, and suggested switches
- `07c5c6f` Search mode: the model searches and reads itself; searches are cached
- `4709a36` Research mode: our own harness with parallel researchers on a roster of models

</details>
<details>
<summary><b>🎨 Artifacts, figures and images</b> (17)</summary>

- `2d0bb47` Give SVG drawings a design brief, six style presets and stable element ids
- `58bfe31` Generate, edit and vectorize images through OpenRouter's image endpoint
- `7fef453` Show generated images as versioned artifacts and send image ids to the model
- `c640574` Draw Mermaid offline and check diagrams and math in a hidden web view
- `b7e923e` Put real diagrams and equations in PDF and Word downloads
- `55e8a30` Sandbox web artifacts and add inline HTML widgets in chat
- `5106fa5` Add editable Excalidraw drawings and make Mermaid diagrams editable
- `5f4e363` Edit artifacts by hand and collect them on an Artifacts page
- `720aff9` Add a Polish button that looks at a figure's render and fixes what's off
- `3022e95` Add a 20-prompt SVG eval with a render gate and a vision-model judge
- `50759b1` Fix the SVG eval cost estimate in its README
- `2608079` Let Polish keep imported vector figures that have no ids
- `ae562d5` Put the sandbox policy before any page content and confirm widget messages
- `80235e7` Load remote images in Markdown only when tapped
- `80be39b` List the libraries bundled in the Mermaid build in the notices
- `28c202f` Keep drawing data valid JSON and send the model a slim copy of saved scenes
- `4b99c0c` Charts: one spec for inline charts and ```chart blocks in documents

</details>
<details>
<summary><b>📎 Attachments, composer and app shell</b> (10)</summary>

- `f54e382` Point at attached photos in the messages instead of sending them twice
- `dd0e571` Paste images and files into the composers, open pictures full size, and clean up unused pictures
- `7aba066` Leave out earlier attachments a newly picked model can't read instead of refusing the turn
- `4163942` Paste copied text as text even when the clipboard also holds a picture of it, and cap rotated photos on their shown long side
- `aff081a` Center the window when its saved position is on a monitor that is no longer connected
- `df0ce4b` Paste text with Cmd+V again in composers that take attachments
- `d159e82` Use one type scale and one menu style across the app
- `6dc94f2` Keep popovers inside the window on phones; drop blurbs from the model picker
- `518bb84` Artifact panel on phones: header below the nav bar, back chevron to the chat
- `b22f889` Keep search fields below the top bar; open row menus beside their button

</details>
<details>
<summary><b>📱 Remote control</b> (7)</summary>

- `151522a` Relay remote Code hosts and paired devices through the backend
- `9e52333` Use Code from a phone, tablet or browser through a paired computer
- `7ec9e6f` Keep hosting on app-wide and announce devices asking to pair
- `f27f608` Keep remote Code links up through large messages and handshake races
- `adbf2c2` Stop hosting and drop remote pairings when signing out
- `adc5811` Remote control: phones, tablets and the web mirror the computer's Code sessions
- `4da66d2` Show the Chat | Code switch on phones before pairing

</details>
<details>
<summary><b>💸 Billing, usage and BYOK</b> (9)</summary>

- `ec3fc3f` Check credit before web searches, follow-ups and image batches
- `8cd0e59` Add a Usage screen with daily and weekly charts by model, kind and provider
- `d731462` Bill Anthropic replies as the model that served, continue paused turns, and bill web searches separately
- `1452de6` Stop passing unmetered Anthropic server tools such as code execution through the gateway
- `cf8b74c` Refuse usage time-zone offsets outside the real UTC range
- `b247215` Backend: run model calls on the user's own OpenRouter or Anthropic key
- `76d6e28` Backend: session totals report what the user's own keys spent
- `8fae0b4` BYOK: bill models to your own OpenRouter or Anthropic key
- `e2e7888` Settings: Add API keys page and a Plans block in Billing

</details>
<details>
<summary><b>⚙️ Settings</b> (2)</summary>

- `c10624d` Settings: one modal with search, an account menu and a reply language
- `413e542` Code settings: typed rows per layer instead of the JSON editor

</details>
<details>
<summary><b>🖥️ Backend and gateway</b> (14)</summary>

- `b984b3d` Keep streamed gateway replies alive while a long tool call is held back
- `74663ff` Use Anole 0.4.1 from its release tag
- `3e6fefc` Use Anole's SSE parser and migration runner
- `9b12742` Remove the local SSE parser and migration runner
- `d05f616` Reject attachments a model can't read, require the account token on remote relay sockets, and refuse dev auth on the LAN without opt-in
- `3fda0fd` Cache Anthropic conversations even when the request mentions cache_control
- `f9c9f01` Gateway: don't continue a cut-off reply when the request uses plugins
- `77e0c84` Backend: fix Google account linking, crash-safe Stripe webhook, transactional billing
- `35db422` Backend build: Anole's web profile without unused features
- `202e5c2` Backend: client timeouts, retries and breaker; per-route deadlines; drain-aware turns
- `5be050c` Backend: rate-limited sign-in and pairing, decoy hash, 401 challenge; .env in development only
- `38414e3` Backend: typed request bodies and field rules; the app shows field problems
- `458d705` Backend: one catalog refresh at a time, backoff after a failure, loaded at start
- `2a99983` Backend: small fixes from the Anole docs audit

</details>
<details>
<summary><b>🧰 Tooling, docs and licence</b> (5)</summary>

- `40d0844` Add the product and Code workspace roadmaps
- `1e4bdae` Show delivered files in the agent eval transcript dump
- `5bb5bcd` Keep scripts/dev.sh from hanging on a stuck backend
- `3cf3509` dev.sh ios-sim: open Device Hub on Xcode 27, wait for boot, clear suspended runs
- `3c68fca` License EveryAI under FSL-1.1-ALv2

</details>
