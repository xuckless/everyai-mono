# AGENTS.md — EveryAI working notes (tracked; a local `CLAUDE.md` symlink to this stays gitignored)

Context for the next agent. Keep it current: update the **Progress log** and
**Next steps** whenever you finish a step. Plans under `~/.claude/plans/` and the TODO*.md files are the
owner's local notes (gitignored); the task board is the GitHub Project.

## What EveryAI is (owner, 2026-11-04)
A coding **harness and orchestrator for every coding agent**: Claude Code, Codex, OpenCode, ACP agents and our own
EveryAI harness in one native workspace, with our workflows, checks, rewind and tools on top. **BYOK** (users' own keys
and subscriptions; EveryAI spends nothing on sessions it doesn't lead), **local AI** next, and outside agents keep
their **native feel**. OpenRouter is plumbing, not the product; billing is parked. Public docs: `README.md`,
`docs/ROADMAP.md`, `docs/CODE_ROADMAP.md`, `docs/ARCHITECTURE.md`, `CONTRIBUTING.md`, `CHANGELOG.md`.

## Rules (from the user — do not break)
- **Commits:** author as your own git identity (the owner's agents commit as
  `xuckless` with the GitHub noreply address). **No Claude/AI identifiers**
  anywhere in commits or PRs. That means no Co-Authored-By, no "Generated with",
  no session links, and Claude is never added as a collaborator.
- **Branch:** `main` is PR-only and needs the owner's review. The owner works on
  `everyai-revamp`; collaborators branch off `main` and open a PR. One commit per
  finished phase or step.
- **Secrets:** never commit `.env` or keys. Use `.env.example`. The OpenRouter
  key (and an Anthropic key) live in the **repo-root `.env`**. Don't scrub
  history; secrets get untracked instead.
- **Anole gaps:** build the tooling locally in backend-exp first, then open a
  PR to `xuckless/anole` with a neutral description. **Ask the user before
  tackling any new gap** beyond the SSE client and migrations.
- **Prototype:** production guardrails are not required yet. Large passes run
  best-effort: write blockers to TODO.md and move on.
- **Eval gate:** every prompt or tool-description change states its reason
  (in the commit body) and must not regress the live Code scenarios
  (`frontend/tool/agent_eval/`) or the SVG set.
  **Suspended during the 2026-10-30 prototype build pass (user):** skip prompt
  testing and live eval gates; the user will test extensively later. An agent
  asked to run an "EVAL GATE" returns at once with status `blocked` and
  summary "skipped by user (prototype phase)". Avoid live model calls unless
  an item cannot be built without one (e.g. a protocol spike).
- **Copying:** copy permissive code (MIT/Apache/BSD) only, with an entry in
  `THIRD_PARTY_NOTICES.md`; prompts are always rewritten in our own words.
  Never copy Anthropic's proprietary docx/pdf/pptx/xlsx skills. Don't copy code
  from Open WebUI, LobeChat, Cherry Studio or Dify, and don't depend on the
  Remotion or tldraw SDKs.
- **The user commits too** (e.g. README edits during a build pass). New commits or a
  brief `.git/index.lock` from them are expected: retry, keep going, and never
  touch or revert their files. The user may also add items to TODO.md mid-run:
  re-read before editing it, change only your own item's line, and don't pick up
  the new items.
- **Long runs:** kill stray processes (servers, zig, flutter) and watch disk
  use, since `.zig-cache` grows without bound. Clear it when large.

## Monorepo map
- `frontend/`: the Flutter app ("EveryAI"), Flutter 3.47.9, Riverpod 3, Drift.
  - One EveryAI design on every OS since the UI overhaul (2026-11-06): tokens in `EveryTheme`
    (`core/theme/`), kit widgets in `core/ui/kit.dart`, motion in `core/motion/motion.dart`, Geist fonts and
    Lucide icons. The `Adaptive*` wrappers in `lib/core/ui/adaptive*.dart` render the kit; one Material root
    supplies plumbing only. The old per-platform design languages (Cupertino, Material, Fluent, macos_ui) are gone
    from the screens.
  - Features live in `lib/features/<feature>/{data,domain,ui}` plus a
    `*_providers.dart`.
  - Chat: `features/chat/` (controller `chat_providers.dart`, transport
    `data/chat_transport.dart`, markdown `ui/chat_markdown.dart`).
  - Models: `features/models/` (catalog, library, shop).
  - Sidebar and shell: `features/history/ui/sidebar.dart`, `app/shell.dart`.
  - Code: a five-tab session panel (Session · Diff · Preview · Files · Processes), a terminal drawer with
    tabs, and the Board (`code/board/`). Live views and the `app` tool are in `code/live/`, the shell registry in
    `code/shells/`, local models in `features/local_models/`.
  - Tests: `flutter test` (app) and `packages/*` tests. Screenshots go through
    the seeded demo DB under the macOS container.
- `backend-exp/`: the new backend in **Zig 0.17.0 on Anole** (the `xuckless/anole`
  tag pinned in `build.zig.zon`). See `backend-exp/README.md`.
  - `zig build run` serves `:8080` with docs at `/docs`.
  - `zig build test` runs 8 unit and 8 integration tests (in-memory routes
    against `openrouter.Fake`).
  - Layout:
    - `src/main.zig`: App state, routes, `prepare` (migrate + dev seed)
    - `config.zig`: env-driven Config; reads `.env` then `../.env`
    - `auth.zig`: JWT (15 min) plus rotating refresh tokens (60 days) and
      `sk-eai-` gateway keys. Middleware `Authenticate{keys}`. With
      `DEV_AUTH=true`, anonymous requests act as `dev-user` (pro plan, $20).
    - `billing.zig`: plans free/pro/max, quota → wallet debit, 402 preflight,
      Stripe checkout (mocked without keys), webhook.
    - `models.zig`: OpenRouter catalog refreshed hourly, marked up ×1.15,
      `:batch` excluded, featured defaults.
    - `chat.zig`: `/v1/chat/stream`, the SSE tool loop.
    - `tools.zig`: the constant system prompt and tool schemas (cache-stable).
    - `gateway.zig`: OpenAI-compatible `/v1/chat/completions` for
      OpenHands/LiteLLM.
    - `images.zig`: `/v1/images`.
    - `openrouter.zig`: upstream client, stream parsing, Fake.
    - SSE parsing uses `anole.sse.Parser`; migrations use `anole.db.migrate` with the list in `migrations.zig` (Anole 0.5.1 since 2026-11-04).
- `docs/`: `ROADMAP.md` (product and moat) and `CODE_ROADMAP.md` (Code architecture and next steps); keep them current.

## /v1 contract (backend-exp ⇄ app)
- **Auth:**
  - `POST /v1/auth/signup|login` takes `{name?, email, password}` and returns
    `{access_token, refresh_token, token_type, expires_in, user{id,name,email,plan}}`.
  - `/v1/auth/refresh` takes `{refresh_token}` and returns the same shape. The
    refresh token **rotates** (save the new one; reusing the old one is a 401).
  - `/v1/auth/google` takes `{token}`; `/v1/auth/logout`;
    `DELETE /v1/auth/account`; `GET /v1/me`.
- **Models:**
  - `GET /v1/models` returns `{object:"list", data:[{id, name, provider,
    blurb, context_length, input_modalities, output_modalities,
    prompt_per_mtok, completion_per_mtok (marked up), free, tools, reasoning,
    web_search, default, created}]}`.
  - `GET /v1/models/defaults` returns `{models:[ids]}`.
- **Chat:** `POST /v1/chat/stream` takes `{model, mode: chat|search|research,
  messages:[{role, content}], tools_enabled, session, reply_language?}` and returns SSE events.
  `reply_language` ("French"; absent or "auto" follows the user's message) adds
  one user-role line after the memory/skills blocks and pins follow-ups to it.
  `content` is a string or OpenAI content parts (`text`, `image_url` data URL,
  `file{filename, file_data}` for PDFs, `input_audio`); bodies up to 32 MiB.
  - `delta {text}` and `reasoning {text}`
  - `sources {sources:[{url,title,snippet}]}`: **new ones only; append**
  - `tool {id, name, arguments}`: a UI tool for the app to render
  - `tool_status {id, name, status: running|done|failed, detail?}`
  - `image {id, mime, data(base64)}`
  - `usage {kind: chat|followups, model, prompt_tokens, completion_tokens,
    cached_tokens, cache_write_tokens, charged_micros}`: one per upstream call
    (follow-ups count toward cost, not context)
  - `followups {questions}`, `done {}`, `error {message, retryable, status?}`
  - **402** `{message, code:"out_of_credits"}` before the stream starts.
  - **Client-executed tools:** the request may carry `client_tools:[names]`
    (UI tools the app runs itself; server tools are never handed over). Such a
    call comes as `tool_wait {id, name, arguments}` instead of `tool`, and the
    loop waits until the app sends `POST /v1/chat/tool_result {call_id, result
    (string or any JSON), is_error?}` (200 `{ok}`; 404 when no turn of this user
    waits for it). The model gets the result (`Error: …` when `is_error`). After
    `CLIENT_TOOL_TIMEOUT_MS` (300 s) it gets `Error (timeout): …` instead. Either
    way a `tool_status {id, name, status: done|failed, detail?:"timed out"}`
    closes the wait. SSE comments keep the stream alive every 15 s meanwhile.
    App side: `chatClientToolsProvider` (names), `ChatController.resolveTool`,
    `ChatSessionState.pendingTools`. Code: `backend-exp/src/tool_wait.zig`.
- **UI tools:** `create_artifact`, `update_artifact`, `render_svg`,
  `render_diagram` (mermaid), `render_chart`, `make_quiz`, `make_flashcards`,
  `make_slides`. Server tools: `web_fetch`, `generate_image`. Schemas are in
  `backend-exp/src/tools.zig`.
- **Gateway:** `POST /v1/chat/completions` with `Authorization: Bearer
  sk-eai-…` (mint one at `POST /v1/keys`) and `X-EveryAI-Session` for
  attribution. LiteLLM prefixes (`openai/…`) are stripped.
- **Images:** `POST /v1/images` takes `{model?, prompt, aspect_ratio}` and
  returns `{mime, data}`.
- **Usage:** `GET /v1/usage/session/:id` returns `{calls, prompt_tokens,
  completion_tokens, cached_tokens, cache_write_tokens, charged_micros,
  last_prompt_tokens, last_completion_tokens}` for a chat conversation or a Code
  session (the composer meter). `usage_events.provider` is openrouter|anthropic.
- **Dev (DEV_AUTH only):** `GET/PUT /v1/dev/upstream` `{anthropic:
  "openrouter"|"anthropic", keys:{openrouter, anthropic}}`: where `anthropic/*`
  chat and gateway calls go (persisted in the `settings` table). Search,
  Research, follow-ups and images always use OpenRouter.
- **Billing:** `GET /v1/plans`, `GET /v1/billing` (plan, quota, wallet,
  recent usage, cached tokens), `GET /v1/usage`, `POST /v1/billing/checkout`
  (`{kind: topup|subscription, amount_cents?, plan?}` returns `{url, mock}`),
  `POST /v1/billing/webhook`.
- **Remote hosts** (`backend-exp/src/remote.zig`, migration 003). A host is a
  desktop running the sidecar; clients are the same account's other devices.
  The backend relays WebSocket frames and never parses a payload. The
  endpoints do the E2E encryption with the public keys exchanged at pairing.
  - `POST /v1/remote/hosts {name, platform?, public_key}` returns 201
    `{id, name, platform, public_key, host_token}`. The `rh_` token is shown
    once. `GET /v1/remote/hosts` returns `[{id, name, platform, public_key,
    online, created_at, last_seen_at, devices:[{id, host_id, name, public_key,
    created_at, last_seen_at}]}]` (approved devices only).
    `DELETE /v1/remote/hosts/:id` and `DELETE /v1/remote/devices/:id` revoke
    at once: live sockets get `revoked` and their next frame closes them (4003
    for a client, 4001 for a host).
  - Pairing, all with the user's JWT:
    - The host asks `POST /v1/remote/pair {host_id}` and gets 201 `{id, code
      "ABCD-EFGH", host_id, expires_at}`: 8 symbols, no I/O/0/1, 5 min, single
      use. The app shows the code as text plus a QR.
    - The client sends `POST /v1/remote/pair/redeem {code, device_name,
      public_key}` (case, dashes and spaces are ignored). It gets `{id,
      status:"pending", device_id, device_token (rd_, shown once), decide_by,
      host:{id, name, platform, public_key}}`. A wrong, spent, expired or other
      account's code is a 404.
    - The host gets a `pair_request` notice and decides with
      `POST /v1/remote/pair/:id/approve|deny`, which also needs the header
      `X-Remote-Host-Token: rh_…` (so a client cannot approve itself). It has
      10 min.
    - The client polls `GET /v1/remote/pair/:id` for `{status:
      open|pending|approved|denied|expired}`.
  - Sockets take their own token in `Authorization: Bearer` or `?token=`:
    - `WS /v1/remote/host` (rh_). A reconnect replaces the old socket, which
      gets `replaced`.
    - `WS /v1/remote/client/:host_id` (rd_, approved only; otherwise 401/403
      before the upgrade).
    - The largest payload is 4 MiB.
  - Framing: **binary = data, text = relay notices (JSON `{type,…}`)**.
    - A client sends and receives bare binary payloads.
    - Host frames start with the **4-byte big-endian channel**: the relay adds
      it to frames from a client and strips it from frames to a client.
    - Notices to the host: `hello {host_id, clients:[{channel, device_id,
      device_name, public_key}], pending_pairings:[…]}`, `client_open
      {channel, device_id, device_name, public_key}`, `client_close
      {channel}`, `pair_request {pairing_id, decide_by, device:{id, name,
      public_key}}`, `replaced`, `revoked`. The host may send
      `{"type":"close_channel","channel":N}`.
    - Notices to a client: `hello {channel, host_online}`, `host_online`,
      `host_offline` (frames sent meanwhile are dropped), `closed`, `revoked`.
  - **App side** (`frontend/lib/features/remote/`): binary payloads are E2E
    frames (`domain/remote_crypto.dart`): `01|v|eph_c` init, `02|v|eph_h|tag`
    accept, `03|counter(8)|ct|tag` data (ChaCha20-Poly1305, per-direction
    keys from 4 X25519 DHs). Inside: JSON mirror messages
    (`domain/remote_protocol.dart`, `Tunnel`): device → host `list`, `open {s}`,
    `close {s}`, `act {id, s, kind, args}`; host → device `sessions`, `reset {s}`,
    `events {s, events}`, `state {s, …}`, `gone`, `done {id, error?}`. **The
    computer runs every session**; phones, tablets and the web are remote
    controls (`host_mirror.dart` runs their actions on the session's own
    controller; devices fold with `MirrorFold` and show `ui/remote_code.dart`).
    Sessions start on the computer only; devices attach pictures and text files
    only; one paired host per device for now. QR: `everyai://pair?c&h&fp&n`.

## Prompt caching (user asked for "proper context caching, for savings")
- The system prompt and tool JSON are compile-time constants with a fixed
  order and no timestamps. Volatile content goes last.
- `anthropic/*` and `google/gemini*` get `cache_control` breakpoints on the
  system prompt and the last message (chat, `CACHE_TTL` 5m). The gateway
  injects breakpoints on the last tool, the system message and the last
  message when the caller sent none (`GATEWAY_CACHE_TTL` 1h).
- Other providers cache on their own.
- Live result: the second agent turn cost 69µ$ instead of 1,113µ$ (94% saved).
  `usage_events` records cached and cache-write tokens.

## Event shapes (from OpenHands, harness removed 2026-10-31)
- The EveryAI harness emits OpenHands-shaped events (`MessageEvent`, `ActionEvent{action:{kind}}`,
  `ObservationEvent`, `ConversationStateUpdateEvent`, …), decoded by `code/harness/events.dart`; the mirror and the
  transcript depend on these shapes. The OpenHands harness, sidecar, agent-server facade and bundling are gone
  (c9b1cb8); sessions stored with `harness: "openHands"` show "can't be reopened". `mcp_config` and skills keep the
  OpenHands JSON shapes.

## Decisions log (user answers, condensed)
- **Coding:** the OpenHands agent-server v1.59.0 (MIT) is a **bundled local
  sidecar**, rebranded with a third-party notice. The UI talks to it over
  REST + WS. Our backend is its LLM provider (per-user gateway key). Desktop
  only for now; a remote harness comes later.
- **Code UI:**
  - top-level Chat | Code switch; auto git worktree per session
  - modes Ask / Auto-edit / Plan / Full auto
  - split transcript + tabbed panel (Diff · Terminal · Processes · Preview)
  - compact tool rows and nested subagent cards
  - mid-run messages queue; ⌥Enter steers
  - per-turn checkpoints with rewind
  - terminal: xterm + flutter_pty; preview webview on mac/win, a window on Linux
  - git: stage/revert hunks, commit+push, PR via gh, merge locally
  - FakeHarness mock mode
  - projects: open folder, clone, or new
- **Question cards (2026-10-29):** the coding agent can ask the user
  questions. Each is single-choice **MCQ (radio)** or **multiple-answer
  (checkboxes)**, every option has a label + description plus an "Other"
  free-text field, and a card holds 1–4 questions, answered together.
  - Plan: an OpenHands **client tool** `ask_user_question({questions:[{question,
    header, options:[{label, description}], multi_select}]})`, registered via
    `client_tools` on `POST /api/conversations` (v1.59 supports client tools
    natively, so no MCP server is needed).
  - The SDK acks the call at once (ClientToolObservation), and the tool
    description tells the agent to end its turn and wait.
  - The app renders the card from the ActionEvent and sends the answers back
    as the next user message (JSON plus a readable summary).
  - The session shows needsInput plus an OS notification. Plan mode uses it
    to clarify before building.
  - Consider the same card for chat (a UI tool) later.
- **Models:** a Shop window (the full OpenRouter catalog) plus **My models**
  (a local list seeded with the featured defaults: Haiku/Sonnet/Opus 5.5,
  GPT-6.1 Sol/Terra, GPT-5.4 mini, and 2 free Chinese models).
- **Billing:**
  - plans Free/Pro/Max plus prepaid top-ups, all at cost ×1.15
  - zero-cost models are free on every plan
  - Stripe test mode, mocked until keys arrive
- **History:** chat history stays **local-only** (Drift).
- **Search:** Search = the OpenRouter web plugin (engine `exa`; native search
  only cites sometimes). Research = `perplexity/sonar-deep-research`.
  Follow-ups come from `google/gemini-3.5-flash-lite`.
- **Order:** A backend core + app switch → B Code UI → C chat tools
  (artifacts, SVG/diagrams/charts, quiz/flashcards, slides→PPTX).

## Progress log
- **Earlier (committed):**
  - rename to EveryAI; pip → uv
  - frontend rebuild: native UI on 6 platforms, Riverpod FSMs, Drift
  - Claude/Perplexity-style chat layout: model picker in the composer,
    centered home, collapsible rail, modes, sources/citations, follow-ups,
    retry/edit
  - macOS rail and vibrancy fixes
  - commits 36d53ad, 9356645, a8fba50, 7b0b6d7, 23642d8
- **2026-10-29, Phase A backend-exp (commit 5da3df4):**
  - The whole `/v1` API is built and passes `zig build test` (16 tests).
  - Live-verified against OpenRouter with Haiku 5.5:
    - search with exa citations
    - the quiz UI-tool loop
    - follow-ups
    - the gateway via the `openai` Python client (non-stream + stream), with
      cache hits
    - `/v1/images` (a 1.2 MB PNG)
    - ledger debits
  - Fixes since then, not yet committed:
    - models: blurbs cut at word boundaries, `~vendor` slugs normalized
    - `/v1/images` takes `model`
    - sources events send only new items
- **Anole PRs #154/#155 merged (v0.4.1) and adopted (2026-10-30):** local `net/sse_client.zig` and `db/migrate.zig` deleted; `Parser.init(gpa, reader, .{})`, `anole.db.migrate(db, ctx, &migrations.all)`.
- **A2 frontend switch (commit 8e96afb):**
  - `/v1` auth with rotated refresh tokens saved; SSE transport with all events; image models through `/v1/images`.
  - Catalog provider, cached under KeyValues `catalog.json` and refreshed hourly. Featured order is Claude, GPT, then the free models.
  - Model shop (`features/models/ui/models_screen.dart`): search, filters, vendor chips, Add/Added.
  - Picker with search; vendor monograms.
  - Billing: `features/billing/`, route `/settings/billing`; Top up on 402.
  - "Rich answers" toggle (`tools_enabled`).
  - Verified live on macOS: search with sources, the quiz tool, shop, plan & usage.
  - `config/dev.json` points at `:8080` with SSE on (gitignored; `example.json` updated).
- **Phase C, first pass (commit 3643e1f), started early at the user's request ("can't interact with the artifact; side window like Claude"):**
  - Code lives in `frontend/lib/features/artifacts/`:
    - `domain/artifact.dart`: `Visual` (decoded tool call), `VisualKind`, and `artifactsIn(messages)`, which groups `create_artifact`/`update_artifact` by id into versions. There are no new tables; history stays in message parts.
    - `artifact_providers.dart`: `artifactPanelProvider(conversationId)` (ArtifactTarget | VisualTarget), `conversationArtifactsProvider`, and `quizAnswersProvider(callId)` (a bitmask per question).
    - `ui/visual_view.dart`: `VisualBody` (renderer switch) and `InlineVisual` (the chat card). Quiz, flashcards, chart, svg and diagram render inline; document, code, html and slides open the panel.
    - `ui/artifact_panel.dart`: header with versions ‹ ›, open in browser (html/diagram), copy, save (file_selector), close. Exports via `exportOf`, plus `pptxOf` for decks.
    - Renderers:
      - `quiz_view` (radio + checkbox `answer_indices`, Check, explanations, score, "Explain my mistakes" sends a chat message)
      - `flashcards_view` (3D flip, keyboard, known/learning)
      - `chart_view` (fl_chart: line, area, bar, scatter, pie)
      - `svg_view` (sanitizer)
      - `web_view` (InAppWebView; Mermaid via the jsDelivr CDN; Linux falls back to source + open in browser)
      - `slides_view` (960×540 canvas, 4 themes, notes)
    - `export/pptx_writer.dart`: a minimal OOXML writer, validated with python-pptx and LibreOffice.
  - `chat_screen.dart`: `_WithPanel` (split ≥720pt, overlay below). Auto-opens on create/update_artifact and make_slides.
  - Composer: a mode menu when narrow; the model chip ellipsizes.
  - New deps: flutter_svg, fl_chart, flutter_inappwebview, file_selector, archive.
  - Verified live: interactive quiz, a document artifact in the panel, chart inline + panel, a slides deck auto-opening, PPTX export.
  - Still missing:
    - quiz/flashcard state is per session (not persisted)
    - no speaker notes in the PPTX (needs a notesMaster)
    - the Artifacts sidebar page is still "coming soon": list `artifactsIn` across conversations via the repository
    - no editing of artifacts in the panel
    - Mermaid offline asset
    - resizable panel divider

- **Phase B, steps 1–2 (commit c531059): Code workspace on FakeHarness.**
  - `frontend/lib/features/code/`:
    - `harness/events.dart`: sealed `HarnessEvent` decoded from OpenHands `kind`s (ChatMessage, ActionCall, ToolResult, StreamDelta, StateChange, ConversationFailure, UnknownEvent). An ActionCall's `action` merges `tool_call.arguments` (client tools) under the typed action.
    - `harness/harness.dart`: `Harness`/`HarnessSession` interfaces and `SessionSpec`.
    - `harness/openhands_harness.dart`: the REST + WS client (untested against a live server). It sends `llm.model` `openai/<id>` with `base_url` pointing at the gateway, registers `client_tools: [askUserQuestionSpec]`, and dedups resent events on reconnect.
    - `harness/fake_harness.dart`: `demoTurns`, a scripted counter-app session. Every action waits for `respond` unless Full auto; the question tool ends the turn.
    - `domain/transcript.dart`: `TranscriptBuilder` folds events into items: UserTurn, AgentText, ExploreGroup (consecutive read-only steps), StepItem, SubagentItem, PlanItem (consecutive updates merge), QuestionItem (an answers message attaches to it), and NoticeItem. `pending` holds every action without a result while status is waiting_for_confirmation.
    - `domain/agent_mode.dart`: Ask (reads are free; commands and edits ask), Auto-edit, Plan (rejects writes and sends the plan prompt), and Full auto (NeverConfirm). `isReadOnly` refuses commands chained with `;&|>`. Also holds `askUserQuestionSpec`.
    - `domain/questions.dart`: Question, QuestionAnswer, `answersMessage` (a summary plus fenced JSON) and `parseAnswers`.
    - `domain/line_diff.dart`: an LCS line diff with folded context.
    - `code_providers.dart`:
      - `harnessProvider` (FakeHarness for now)
      - `codeProjectsProvider` and `codeSessionsProvider`, JSON in Preferences `code.projects` / `code.sessions`
      - `codeSessionProvider(id)`: the controller. It auto-responds per mode, queues messages while busy, `steer` interrupts and sends, `startBuilding` switches Plan to Auto-edit.
    - UI:
      - `ui/code_home.dart`: `/code`, with the project picker, "Try the demo" (`demo://counter-app`), and recent sessions
      - `ui/session_view.dart`: `/code/s/:id`
      - `ui/code_composer.dart`: Enter sends or queues, ⌥Enter steers, Esc stops; mode menu
      - `ui/transcript/`: items, `question_card.dart` (radio/checkbox + Other, 1–4 questions, ⌘↩ submits), `approval_card.dart`
    - Sidebar: a Chat | Code switch; Code mode lists projects → sessions with status dots.
  - Tests: `test/features/code_test.dart` (9).
  - Verified live on macOS: demo session → question card → approvals → edit diff → subagent → tests → Done.
  - UI fixes in the same commit, at the user's request:
    - the chat user bubble is right-aligned (wrapped in `Align`)
    - the Code composer model label sits at the right
    - macOS page titles: `AdaptivePage` shifts the ToolBar title by `_macTrafficLightInset` (ToolBar reserves 70pt when macos_ui's own sidebar isn't used)
  - Live UI testing: `scratchpad/type.sh` and `cmdenter.sh` refuse to type unless EveryAI is frontmost (a stray keystroke once landed in the terminal); `scratchpad/scroll x y lines`.
  - Not done yet:
    - no panes (Diff/Terminal/Processes/Preview)
    - no worktrees or git
    - no sidecar
    - sessions reopened after an app restart are empty (FakeHarness doesn't persist; the real server replays history)
    - no OS notifications

- **Brand reskin (commit 2f1323c), from the user's `brand/` kit (v1.0; the folder stays untracked, it is the user's source of truth; see `brand/README.md`):**
  - Tokens: `lib/core/theme/everyai_brand.dart` (copy of the kit's Dart tokens). `EveryTheme` maps the README role table; filled buttons use `primary`/`onPrimary` (violet 500 + white in both themes); `accent` is for text/links/icons. Statics `cardRadius` 20, `panelRadius` 24, `bubbleTail` 6.
  - `lib/core/ui/brand.dart`: `BrandMark`, `EveryMarkActivity(thinking|streaming|tool)` (CustomPainter from the mark parts), `BrandGlyph(name, active)` (paths in generated `brand_glyphs.dart`), `BrandEmptyState`, `BrandField`.
  - `GlassSurface(level: thin|regular|thick)` in `adaptive.dart`; popovers and toasts are thick.
  - `AdaptiveButton` is compact by default (Cupertino small, macOS regular, Material 34pt dense, 14pt labels); `large:` (defaults to `expand`) for full-width form buttons.
  - `Host.hasTrafficLights` (macOS host, any design language) drives the sidebar's 92pt title-row inset; before this the lockup sat under the traffic lights in Cupertino.
  - Icons: macOS/iOS (single 1024 with dark + tinted)/Android adaptive + monochrome/Windows ico/web/Linux hicolor (CMake install + `gtk_window_set_icon_from_file`, not compiled yet). Splash via `dart run flutter_native_splash:create` (config in pubspec).
  - Verified on macOS (Cupertino design, which the user runs): chat, Code home and session (the mark animates while working), shop, question card, light mode.
  - Not used yet: avatar (for "EveryAI · Auto"), Icon Composer layers, patterns, grain overlay.

- **Real agent-server wired up (2026-10-29):**
  - `frontend/tool/fetch_agent_server.sh` downloads `agent-server` v1.59.0 for this OS/arch into `frontend/.agent-server/` (gitignored) and checks SHA256SUMS.
  - `features/code/sidecar/` (conditional `_io`/`_stub`): `createSidecar()` either uses `AGENT_SERVER_URL`+`AGENT_SERVER_KEY` or spawns the binary (`AGENT_SERVER_BIN`, else bundle Resources / app-support `bin/`) on a free loopback port with a random `OH_SESSION_API_KEYS_0`, stable `OH_SECRET_KEY` (`secret.key`), cwd = app support `agent-server/` (conversations persist in `workspace/conversations`, log in `server.log`, `server.pid` lets the next launch kill an orphan). Polls `/ready` (~8–15 s cold). Stopped on Cmd-Q via `AppLifecycleListener`.
  - `code_providers.dart`: `harnessFor(ref, workingDir)` (demo:// → FakeHarness, else OpenHandsHarness on the sidecar) and `gatewayKey(ref)` (POST `/v1/keys` once, kept in prefs `code.gateway_key`; unauthenticated when `DEV_SKIP_AUTH`, like billing). LLM base URL = `API_BASE_URL` + `/v1`. FutureProviders read with `ref.read(.future)` hung here, hence plain functions.
  - `createSampleProject()` makes a Dart counter repo under app support `sample-projects/` ("Sample project" button / project picker); the scripted demo is still there.
  - OpenHands quirk: the `task` tool (subagents) breaks conversation create in 1.59.0; removed from the tool list.
  - macOS app is **unsandboxed** now (entitlements); the DB moved to Application Support (`core/db/db_location_io.dart` copies the old container DB on first run).
  - Verified live: Ask-mode session on the sample repo with Haiku via the gateway → explore, approve, edits + tests, `dart test` 3/3, Done. Ledger: 7 gateway calls, 58% of prompt tokens cached.
- **Launcher (no local backend):** `scripts/launch.sh [build] [macos|linux|windows|web|ios-sim|ios|android|<device>]
  [-- flutter args]` runs or builds the app against the deployed dev server (`EVERYAI_API` overrides it), installing
  Flutter/CocoaPods with Homebrew when missing; defines in `.dev/defines-launch.json`. `Launch Flutter (macOS).command`
  = `launch.sh build macos` + open.
- **Dev runner:** `scripts/dev.sh [macos|web|ios-sim|ios|<device>] [-- flutter args]` starts backend-exp (reuses one on :8080), fetches the agent-server for macOS, writes `.dev/defines-<target>.json` from `config/dev.json` with the right `API_BASE_URL` (LAN IP + backend `HOST=0.0.0.0` for a physical iPhone), and `flutter run`s. New backend setting `HOST` (default 127.0.0.1).
- **Web/iOS:** web needs `web/sqlite3.wasm` + `web/drift_worker.js` (added, from drift 2.35.3); verified loading the catalog from the backend. iOS Simulator build verified (this Xcode has no Simulator.app; it runs headless, `xcrun simctl io booted screenshot`). The Code switch shows on desktop hosts only.
- **Type scale:** Cupertino on a desktop host uses desktop sizes (`_desktopCupertinoText`, 14pt body; text fields 14.5); lighter sidebar/headlines.

- **Meter, attachments, Anthropic key (2026-10-29; commits 59ae160, 4c4b51b, 114106d):**
  - `backend-exp/src/anthropic.zig`: native Messages adapter behind `openrouter.Upstream`. It translates OpenAI requests (system hoisted, tool_use/tool_result merged, image/PDF blocks, cache breakpoints capped at 4, sampling params dropped, forced tool_choice → auto, adaptive summarized thinking, `fallbacks:"default"` on Sonnet/Opus 5.5) and turns Anthropic SSE/JSON back into OpenAI chunks. Cost comes from catalog prices (`Catalog.pricesOf`: 5m/1h cache writes, the >100K tier). `App.route(model, native_ok)` picks the upstream.
  - The key is **`ANTHROPIC_API_KEY`** in the root `.env`; `CLAUDE_API_KEY` there is rejected by the API (401). Thinking blocks are not sent back; the 5.5 models accept tool loops without them (probed).
  - Verified live on the Anthropic key: chat tool loop with cache reads, the gateway (stream + non-stream), image+PDF+text attachments (same answer and ~same cost via OpenRouter), and an OpenHands session with an image ("Red"), attributed via `/v1/usage/session`.
  - App: Settings → Developer ("Claude models bill to"), `features/settings/dev_upstream.dart`. The switch is currently **on Anthropic**.
  - `features/usage/`: `UsageTotals`, `formatTokens`, `UsageMeter` + `ContextRing` (popover breakdown). Chat saves a `UsagePart` per turn; Code polls the session endpoint after OpenHands `stats` events (`codeUsageProvider`) and sends `max_input_tokens`.
  - `features/attachments/`: `Attachment`/`AttachmentKind` (limits, `ModelSpec.accepts` via the new `ModelSpec.inputs`), `pickAttachmentFiles` (native picker greys out unsupported types), `AttachmentDropZone` (desktop_drop), `AttachmentTray`/`AttachmentChip`. Chat: `AttachmentPart` (Blobs), `messageContent` builds content parts. Code: `uploads/` saves into `<project>/.everyai/uploads` (git-excluded), `[Attached: …]` note (rendered as chips), images as OpenHands `ImageContent` with `capability_overrides.supports_vision`.
  - Not verified by clicking through the macOS UI (the machine was in use); the picker, drop zone, tray and meter were checked by analyze/tests only.

- **Code bug fixes (2026-10-30; commits c6cd611, 9183510, dd41963)**, from the user's report that question cards deactivate, Plan mode refuses everything, and agents turn into chatbots:
  - Root causes, found in the agent-server's persisted events:
    - `openQuestion` only counted the last item, so the agent's follow-up text disabled the card.
    - `isReadOnly` refused any `; & | >`, so Plan rejected every exploration command and Ask asked for every read.
    - Mode changes were never told to the model.
    - Session events were broadcast-only, so events before the view subscribed were lost.
    - The transport and gateway were fine.
  - `domain/shell_readonly.dart`: a quote-aware classifier with per-segment allowlists, git read subcommands, and `/dev/null` and fd redirects; `$(…)`, subshells, heredocs and `&` are refused.
  - Mode notes:
    - `modeNote`/`splitModeNote` (`<everyai-mode name="plan">…</everyai-mode>`) go on the first message and on the first message after each switch.
    - `Transcript.notedMode` tracks the last note, and `UserTurn.mode` shows a chip.
  - Prompts:
    - `workingRules` go into `agent.agent_context.system_message_suffix` (verified in the SystemPromptEvent).
    - `AgentMode.planRefusal` explains what still works.
  - The `present_plan` client tool gives a `PlanProposal` item and `ui/transcript/plan_card.dart` (Start building switches Plan to Auto-edit; Keep planning).
  - The question card is paged (tabs, Back/Next, number keys, still-to-answer). A free-text reply settles it as "answered in chat".
  - The harness:
    - `OpenHandsHarness.located(locator)` re-resolves the sidecar before each request and reconnect.
    - The session buffers history and replays it to every listener.
    - `ConnectionChange` events drive a reconnecting banner; attach returns a 404 as a clear error.
    - `statuses(ids)` feeds `codeStatusesProvider` for sessions that aren't open.
  - `tool/agent_eval/`: `driver.dart` (`EvalRun`, a headless controller that plays the user), `scenario_test.dart`, and `restart_check_test.dart`. These are live; run them explicitly with env vars (see their headers). Use a private agent-server on its own port (not the app's).
  - Live, on Haiku 5.5 via the Anthropic route:
    - Plan: explore, 4 questions, present_plan, approve, build, tests, done (40 s).
    - Ask: the same with the user's form prompt.
    - Restart: the session followed a new port and key with no lost or duplicated events.
- **PDF → Markdown freeze (commit a917d19):** Haiku read the PDF fine and made a markdown artifact with TeX in table cells. `IntrinsicColumnWidth` measures cells, so the paragraph asks the inline math for `computeDryBaseline`. flutter_math_fork's `RenderLine` lacks it, so layout failed every frame and the debug app froze. `everyai_markdown/lib/src/render/math.dart` wraps math in `_DryBaseline` (estimates from the dry size). The regression test is `test/math_layout_test.dart`. App run logs only go to the terminal that ran `flutter run`. The chat DB is `~/Library/Application Support/dev.alidirect.everyai/everyai.sqlite` (tables `conversations`, `messages`, `message_parts`, `blobs`), useful for replaying what the model sent.

- **Artifacts: in-place edits, figures, downloads (commit dc3c90c, 2026-10-30):**
  - `edit_artifact {id, edits:[{old_text,new_text}]}` in `tools.zig`. `chat.zig` `Artifacts` seeds content from `<artifact id kind title>` blocks in history, applies the edits and replies with misses (an edit with no matches isn't shown).
  - The app now sends what UI tools made in earlier turns (`toolOutputsByMessage` in `chat_transport.dart`); before this the model never saw its artifacts after the turn and re-created them.
  - `artifactsIn` applies edits (`applyArtifactEdits`, whitespace-tolerant; `edit_missed`).
  - ```svg / ```mermaid blocks render in `ChatMarkdown`; raw `<svg>` blocks get fenced (`fenceRawSvg`).
  - `artifacts/export/`: `doc_model.dart` (GFM → blocks), `pdf_writer.dart` (pdf pkg, Noto Sans in `assets/fonts/NotoSans`), `docx_writer.dart`, `svg_raster.dart`, `downloads.dart` (`downloadsOf`, `exportOf`, `pptxOf`); `ui/download_button.dart` on cards and panel.
  - Live: Haiku edited the assignment doc in place with an inline SVG ($0.007); the saved PDF (8 pages) had the figure.
- **Research docs (untracked):** `docs/research/opencode-agents.md`, `hermes-agent.md`, `hermes-chat-tooling.md`, `deepseek-harness.md`.

- **Build pass, tracks 0–1 (2026-10-30; commits d9d0bd4..d2081ad, then 74663ff):**
  - Chat: tool-use enforcement and artifact rules in `tools.zig`; typed tool errors (`tool_check.zig`, schema-driven); client-executed tools (`tool_wait.zig`, SSE `tool_wait`, `POST /v1/chat/tool_result`, `ChatController.resolveTool`); truncation recovery in chat and gateway; SSRF-safe `net/safe_fetch.zig` for web_fetch; DeepSeek cache hits.
  - Code: mode re-asserted on every message; question/plan answers held inside the tool call (respond_to_confirmation); our own permissions (floor, allow/deny, dangerous classifier, once/session/always, denial templates; no NeverConfirm); AGENTS.md/CLAUDE.md injection with nested hints; Stop kills the session's process tree; doom-loop guard; output spill to `.everyai/spill`; `compact()` into a fresh conversation; `run_subagent` child conversations; rich tool rows with highlighting; live Changes/meter.
  - Review fixes: cloned repos can't approve their own commands or read outside the repo; floor/readonly bypasses closed; Stop spares tmux panes.
  - Anole is now the v0.4.1 tag (url + hash in `build.zig.zon`), not the local path.
  - Not live-tested (user defers testing). Leftovers are sub-bullets in TODO.md.

- **Build pass, tracks 2+4 (2026-10-30; 74663ff..3d6ff3f):**
  - Images via OpenRouter `/images` (`images.zig`): `n`, quality, `input_references`, ids `img_<n>`/`upload_<n>`, `edit_of`; Recraft vector engine (`VECTOR_MODEL`); image artifacts with versions (`image_view.dart`).
  - `web.zig`: model-callable `web_search`, one source ledger for all citations, paged `web_fetch` (`offset`, `max_chars`).
  - Reasoning passback within a turn, `effort` request field + composer EffortMenu (per chat). Aux routing table for side jobs; follow-ups pinned to the user's language.
  - SVG design brief, 6 style presets after the cached prefix, stable ids; `/v1/figures/polish` (`polish.zig`); SVG eval assets (not run).
  - Chat `ask_user` card (client tool); local memory (`features/memory/`, memory + search_chats client tools, Settings → Memory).
  - Artifacts: Mermaid/math checks in a hidden webview with PNGs in PDF/Word, offline Mermaid asset, sandboxed HTML (CSP meta first), inline widgets (send-back confirmed), Excalidraw drawings, hand-editing, PPTX notes, Artifacts page, resizable divider, persistent quiz/cards.
  - Review fixes: credit preflight for search/follow-ups/image batches, remote Markdown images load on tap, memory kept out of system authority.
- **Code MCP servers (commit 834795a):** Settings > Code > MCP servers (`/settings/mcp`), global or per project, stored in Preferences `code.mcp_servers`; passed as `agent.mcp_config` (1.59 shape: `{name: {command,args,env} | {url,transport,headers}}`). Local commands need consent of the exact command+args+env (`McpServer.approved`); `reviewMcpServer` reuses `floorReason`/`dangerReason`. `MCPToolAction` is never read-only: Ask/Auto-edit/Plan ask, Full auto runs, `Mcp(glob)` rules match the tool name. 1.59 has no MCP elicitation handler.

- **Build pass, tracks 3+5 (2026-10-30; 3d6ff3f..336a1ff):**
  - Code MCP servers (`code/domain/mcp_servers.dart`, `/settings/mcp`): flat `mcp_config` map (verified against SDK v1.59.0), consent review, presets (Playwright, Penpot, AntV, draw.io; not installed). MCP calls always ask except in Full auto. Elicitation needs the backend MCP client.
  - Skills (`features/skills/`, `/settings/skills`): sent as `agent_context.skills` (agentskills format; server folder scans stay off); inline `!cmd` lines escaped; strict import validator; project skills digest-trusted. Chat: client-executed `load_skill` / `read_skill_file`. Bundled Apache-2.0 skills in `assets/skills/`.
  - Slash (`features/slash/`): one `/` popover in both composers; custom commands `.everyai/commands/*.md`; Chat and Code built-ins incl. /btw, /review, /goal (judge), /commit, /pr, /learn, /morning.
  - Known gap: project custom commands from cloned repos have no digest trust gate yet (mode switch restricted only).

- **Build pass, track 6 + Code workspace (2026-10-30; 336a1ff..0a0a7bf):**
  - Agent library (`features/agents/`, `/settings/agents`): `.everyai/agents/*.md`, built-ins in `assets/agents/`, digest trust for project agents; `run_subagent` takes `agent`.
  - Ultra (`code/ultra/`): `ultra_plan` client tool → pure-Dart engine (phases, parallel/pipeline, worktrees per writing step, schema retry, verify, critic), caps 16/150/$25/2h, Max only, journal resume; progress tree UI. Orchestrator spend is now counted in the cap.
  - Code UI: Harness → Model → Effort popover with live `switch_llm`, no bottom sheets, Code top bar with layered settings JSON + system prompt + budget; panes Terminal (xterm + flutter_pty), Processes, Preview; `present_files`; OS notifications (osascript/notify-send).
  - Infra: gateway key in secure storage with re-mint on 401; sidecar crash restart + reattach; agent-server bundled into the macOS app; conversation rewind via fork/navigate.
  - Remote host: `backend-exp/src/remote.zig` relay (opaque E2E frames, pairing codes) + `features/remote/` (X25519 + AEAD, QR, RelayHarness). Pairings are cleared on sign-out.

- **Build pass, leftovers (2026-10-30; 0a0a7bf..HEAD):** Anole 0.4.1's `sse.Parser` and `db.migrate` adopted (local copies deleted; list in `src/migrations.zig`); Anthropic adapter prices the served model, continues `pause_turn`, `by_kind` usage; modality guard (400 `unsupported_modality`); relay sockets need the user's JWT; `DEV_AUTH_LAN` guard; usage aggregates (`/v1/usage?group=&by=`) + Settings → Usage; clipboard paste, blob GC, full-size images; trust gate for project custom commands; window persistence; `docs/ROADMAP.md`, `docs/CODE_ROADMAP.md`. Final state: zig 91/91 steps, flutter analyze clean, 613 flutter tests pass. Nothing in this pass was live-tested.
- **Remote control (2026-10-30, commit adc5811):** the old "phone drives the host's agent-server"
  path (`RelayHarness`, `remote://` projects) is gone. The Mac's `CodeSessionController` exposes
  `mirrorEvents` + a sync `mirrorTap`; `HostMirror` streams them (deltas too) plus a state snapshot
  (mode, queue, approval flags, remember patterns) to every device following a session, and runs
  device actions there, so several devices and the desktop drive one session together. Off desktop,
  `/code` and `/code/s/:id` route to `RemoteCodeHome` / `RemoteSessionScreen`; the sidebar lists the
  host's sessions; Settings → Remote shows hosting on desktop and pairing elsewhere.
  `test/features/remote/mirror_test.dart` covers transport + an end-to-end mirrored FakeHarness session.
- **Type scale + one menu style (commit d159e82):** `core/theme/every_type.dart` `EveryType` (largeTitle/title/headline/body/callout/caption/footnote/micro, desktop vs touch sizes, max semibold) via `EveryTheme.type` plus `.medium/.semibold/.mono/.tint()`. No literal font sizes in screens (except slides canvas, PDF export, avatars). Cupertino text theme built from it on iOS too. `AdaptiveMenuButton` = `AnchoredPopover` + `PopoverRow` on every platform; `MenuTrigger` for value pickers. Not checked visually on iOS yet.

- **Chat harness per mode (2026-10-30; d35d61b..4709a36):** plan in `~/.claude/plans/calm-strolling-swing.md`.
  - Question cards: options ending " (Recommended)" show an accent tag (Code + chat specs ask for it).
  - Charts: one spec (`artifacts/domain/chart_spec.dart`) for `render_chart` and ```chart blocks in Markdown
    artifacts; fl_chart in the app, `export/chart_svg.dart` for PDF/Word/PNG/SVG; CSV + data table. Server flags
    bad ```chart blocks after artifact calls.
  - Modes: `backend-exp/src/modes.zig` constant block per mode as a 2nd system part (own cache breakpoint).
    Learn, Summarise, Search (model-driven web_search/web_fetch; plugin only without tools), Research.
    `suggest_mode` UI tool → "Run as <mode>" button (`rerunIn`). Slash: /teach (Learn; /learn is make-a-skill), /summarise.
  - `web.SearchCache`: per user+chat, 1 h, 300 entries; repeats are free and marked.
  - Research (`research.zig`): lead = user's model; `research` tool runs researchers in parallel on a roster
    (tiers by depth Quick/Standard/Deep), shared ledger behind a lock; report gating, citation check, one nudge.
    App: depth menu, researcher live steps, usage kind `research`. Sonar only as no-tools fallback.
  - Not done: `summarise_parts` map-reduce for over-long sources; no live run yet (eval gate suspended).
- **Backend audit against the Anole docs (2026-10-30; 77e0c84..2a99983):**
  - Security: Google sign-in keyed on `sub` only (verified email for new accounts, a taken address is 409, never linked);
    `/v1/auth/*` rate-limited 10/min per address and pairing 10/min per user (`App.limiter`); decoy Argon2 hash for
    unknown emails; 401s send `WWW-Authenticate`; `.env` files are read only in development.
  - Billing: `charge`, `startPeriod` and period renewal run in `app.db.transaction` (the `...In(db, ctx, …)` helpers take
    the client or a `Tx`); the Stripe webhook binds a typed event with optional fields (signed-event test).
  - `Upstream.post` / `openrouter.complete` take `openrouter.Ctx` (= `anole.db.Ctx`, `ctxOf(req)`); researchers use their
    own Ctx; the research group is cancelled on early return.
  - Build `.profile = .web` minus unused features (91 → 61 steps). Client: 60 s timeout, retries, breaker; the default
    30 s request deadline with `req.setTimeout` on slow routes; turns end retryable when the server drains.
  - Typed bodies (`FetchBody`, field_rules on images/polish; `bindWith` where a field is a `std.json.Value`); the app's
    error parser shows the first 422 field problem. Catalog: one refresh at a time, 60 s backoff, loaded at start.
  - Not done, on purpose: `anole.cached` on /v1/models (the app always sends Authorization, which the cache skips);
    WebSocket idle timeout (the relay client never pings, so it would cut idle sessions; needs a protocol heartbeat);
    jobs cron (no jobs store); Duration-typed config (would change the env formats).

- **Settings overhaul, Steps 1–3 of `~/.claude/plans/settings-ui-overhaul-i-modular-bubble.md` (2026-10-30):**
  - Settings is a modal (`features/settings/ui/settings_modal.dart`, `showSettings(context, section:, anchor:, args:)`):
    ≥760pt a centered glass modal with search + grouped section list; narrower a drill-down. `settings_registry.dart`
    holds `SettingsSection`, the search index (`settingsEntries`), `settingsTargetProvider` (jumps) and
    `SettingsAnchor` targets. Old `/settings/*` and `/code/settings?…` routes redirect to where the user was and open
    the modal (`pendingSettingsProvider`, shell). Screen bodies are `…Body` widgets (no AdaptivePage).
  - Account row + menu: `settings/ui/account_menu.dart` (placeholder name/plan; help/apps/learn more are dead).
  - Reply language: pref `chat.reply_language` → request `reply_language` → `chat.zig` adds one user line after
    memory/skills and pins follow-ups (`routing.fixedLanguage`).
  - Code section: `code/settings/setting_defs.dart` catalog + `code/ui/code_settings_section.dart` (Global | Project
    with "Just me" | Session rows, + Add setting, View as JSON, See full prompt, `PermissionsEditor` + rule builder).
    Files via `settings.dart` `readLayer`/`writeLayer` (atomic, unknown keys kept). Project allow rules go to the app
    store (project files can't allow). The JSON editor (`code_settings_screen.dart`, `parseLayer`) is gone.
  - BYOK UI (`settings/ui/api_keys_section.dart`, `byok_keys.dart`, keychain `byok.<id>`, unused) and static Plans
    (`billing/ui/plans_preview.dart`, anchor `plans`). `AdaptiveSegmented` (`core/ui/segmented.dart`);
    `showAdaptivePrompt(obscureText:)`. No macOS click-through yet (TODO.md §10).

- **Harness: retries, per-call approvals, gentler compaction, model families (2026-10-30; 6a856c0..0fc7f33):**
  - Retries: `GatewayClient.completeWithRetry`/`raw(retry:)` resend on 408/409/425/429/5xx/529, drops and mid-stream overloaded/rate-limit errors, not after a tool call started streaming. 8 attempts (15 for Max/Ultra), backoff 1→60 s ±25%, Retry-After honoured up to 5 min. Transient `ConversationStateUpdateEvent{key:"retry"}` → `RetryState` → `Transcript.retry` / `RetryRow` (Retry now / Stop; mirror action `retry_now`). The gateway forwards upstream `Retry-After`; Anthropic 529 → 503 with `code: 529`.
  - Approvals: one decision per action id (`respond(callIds)`; none = all undecided; `PerCallApprovals`). Refused calls return as refusals and the run continues; only Deny all or Stop parks it. Controller auto-answers per call (`CodeSessionState.decided`, `rememberBy`); `ApprovalCard` stacks rows under Allow all / Deny all. OpenHands stays batch-wide.
  - Parallel reads: read-only bash (`runsInParallel`) batches with the read tools, up to 8 at a time.
  - Compaction: `clearOldToolOutput` (>40K tokens of output older than the last 3 model steps → 20K, placeholder) before summarising; continuation re-injects `<approved-plan>`, `<todos>`, `<files>` (last 5 touched, 8K/30K, marked read), `<skills>`. State in `state.json`.
  - Families: `model_family.dart` `familyOf` fixed per session; `familyRules` `<MODEL-NOTES>` after `harnessRules`; GPT gets our own V4A `apply_patch` (`apply_patch.dart`) instead of edit/write, treated as edits per file.
  - Verified: analyze clean, 686 flutter tests, zig tests pass. Not live-tested or clicked through.

- **BYOK, UI fixes, Gemini/Kimi run fixes (2026-10-31; b22f889..39b53c2):**
  - BYOK: only OpenRouter (every model + side calls) and Anthropic (`anthropic/*`, native adapter). Keys in the keychain
    (`byok.<id>`); the app sends the chosen one as `X-Provider-Key-OpenRouter|Anthropic` (`ModelBilling.headersFor`,
    snapshot `ModelBilling.current` for the Code gateway client). Backend `byok.zig`, `App.routeFor`/`App.aux`: calls on a
    key skip preflight, record `provider = openrouter-byok|anthropic-byok`, charged 0; `/v1/usage/session` adds
    `byok_cost_micros`. Per-model biller pick in the shop (Add menu when >1 account; prefs `models.billers`); default =
    most specific key. Ultra open on own-key models, capped by session budget or `byok.ultra_cap_usd` ($25).
    Not covered: Search mode without tools on a Claude model with only an Anthropic key falls back to credits (needs the
    OpenRouter web plugin). Nothing live-tested.
  - `AdaptivePage.header` pins a search/filter header below the translucent bar (Chats, Artifacts, Model shop).
    `AnchoredPopover` positions from the trigger's rect (hover-faded triggers made panels jump to the window corner).
  - Harness: mid-stream errors retried by message too; gateway `: progress` no longer blocks retries; fork brief says
    phase notes aren't theirs; research refusals before approval; refused writes claim no files; pkill/killall of user
    apps is a floor; mkdir under scratch in the plan phase. Open: a shared per-model rate limiter (Gemini new-account
    20 RPM), a built-in screenshot tool (Kimi spent 8 min trying), forks waiting on approvals nobody sees.

- **Orchestrator, big files, debugging tools (2026-10-31; 302e85c..bf5d5ce):**
  - Fork questions: a fork's `ask_user_question` is held and routed to its orchestrator as `<fork-question>` (held call
    returns `forkAsks`, siblings move to the background; background forks get a message). Orchestrator tools
    `check_forks`, `answer_fork`, `stop_fork` (client tools answered in `CodeSessionController._syncForkTools`; child
    `answerFromOrchestrator`). Tier block `_orchestrating`: monitoring forks is the main job, integration is "done".
    `PhaseFlow.forkAsking` lets the user be asked during research; `onAnswer(callId:)` reads per-call reports.
    Not covered by a controller-level test (harness + phase tests only).
  - `write` `mode: "append"`, ~300 lines per call in the schema, oversize writes land with advice, cut-off writes get
    escalating advice (`_cutOffAdvice`). Research summary in the commit body (Cline/Roo/opencode/Gemini CLI/Plandex).
  - `browser` tool (`browser_io.dart`, CDP over WebSocket, headless Chrome with a per-session profile in the session
    dir; closed at run end/stop) and `screenshot` (`window_capture_io.dart`: JXA window list + `screencapture -l`, only
    windows of processes under the session's shells or run from inside the project). Debugging section in rules.

- **2026-10-31, later:** Option-Enter steer fixed (a message sent while the stopped run unwinds now runs; harness
  test), shortcut hints via `Host.enterKeys` (text-style ↩, Ctrl/Alt+Enter off Apple; approvals take Ctrl+Enter).
  README rewritten for the harness/modes/BYOK/remote, with the BrowserOS benchmark (`docs/benchmarks/browseros/`) and a by-area index of all commits since 6e4c6c5.
  Licence is applied (FSL-1.1-ALv2, user commit 3c68fca).

- **Typed decide, run_script (codemode + RLM), summarise_parts, Auto (2026-10-31; d2a69f3..acae8ab):**
  - Backend `src/decide.zig`: `POST /v1/aux/decide` (JWT or sk-eai key, `X-EveryAI-Session`) `{job?, text, instructions?,
    questions:[{id, kind: bool|choice|score, prompt, choices?}]}` → `{answers:[{id, value}], model, charged_micros}`;
    value or "unsure" (never `p`); strict json_schema, bad replies → unsure; usage kind `decide`. Internal
    `decide.decide(...)`. Env `AUX_DECIDE_MODEL`, `AUX_SUMMARISE_MODEL`.
  - Chat `summarise_parts {url, question}` (`src/summarise.zig`): ~12K parts, decide scores, top 12 (+unsure, ≤24)
    summarised 6 at a time, merged with `[part N]`; `tool_status` progress; usage kind `summarise`.
  - Auto (`src/auto.zig`): `model: everyai/auto` decides mode/rich/tier before the turn, SSE `route {model, mode,
    tools_enabled}` first; `AUTO_FAST|BALANCED|BEST_MODEL`; listed first in `/v1/models`. App: picker entry, `RoutePart`
    chip "Auto · Search · Sonnet 5.5" with re-run; usage labels Decisions / Long reads; `core/api/decide_client.dart`.
  - Code `run_script` (`harness/everyai/script_io.dart`): TypeScript in Deno with no permissions; stdin/stdout bridge
    readFile/grep/glob (project only, no secrets), webFetch/webSearch, decide/rank, llmQuery (utility model; `script:
    true` = depth 2). Read-only (`ScriptAction`), no approval. Caps per tier in `settings/script_caps.dart` (`ScriptCaps`
    on `SessionSpec.script`); Claude/GPT/Gemini by default; Settings → Code → Scripts. Deno 2.9.8 via
    `tool/fetch_deno.sh` / `DENO_BIN`. Transcript `_ScriptView`.
  - Compaction: Thorough+ asks decide which old tool outputs the work still needs; those are cleared last.
  - Bug fix: decide checks a no-`expect` repro shows this bug ("other" refused); verify refuses changed repro tests/scripts
    (snapshot at reproduce, additions allowed, or after asking the user); phase notes point at run_script and git bisect.
  - Approval risk label (`code/approval_risk.dart`, informational only).
  - zig tests pass (96 unit, 55 integration); flutter analyze clean, full flutter test passes. Nothing live-tested.

- **OpenHands removed, Deno bundled, quick wins (2026-10-31; 0890207..7da3ddf):**
  - c9b1cb8 removes the OpenHands harness, sidecar, facade, `CodeHarnessKind`, tier cap, fetch/bundle scripts and their
    tests; `HarnessError` is in `harness/harness.dart`; `code/sample/` holds `createSampleProject`; agent_eval keeps
    `scenario_test.dart` on the EveryAI harness. 178c40a: `macos/scripts/bundle_deno.sh` puts Deno in
    `Contents/Resources` (signed; `deno.entitlements` JIT).
  - Chat: starter chips switch mode (`chat/domain/starters.dart`), backend titles after the first reply
    (`chat/data/chat_titles.dart`, `ChatRepository.renameIf`), `/model` opens the picker, account row from `/v1/me`
    (`auth/profile.dart`), risk label carries the session.
  - Harness: `.everyai/plans/` saved plans and `.everyai/memory.md` + `memory` tool (`project_notes_io.dart`, loaded
    into new sessions' prompts; tracked files ignored), third identical call not run, `max_tokens` fitted to the window.
  - flutter analyze clean, 732 tests pass. Not live-tested. 4 empty commits await the user's OK to drop (TODO.md).

- **No-env run (2026-10-31, d5fd061):** `JWT_SECRET` optional in development (random per run), `OPENROUTER_API_KEY`
  optional (`App.keyless`; chat 400 `no_api_key`, gateway 401, client's own no-key reply; catalog fetched without a
  key; dev credits only with a server key). App banner "Add API key". A fresh clone needs only `scripts/dev.sh` and a
  key pasted in Settings → API keys (verified: binary started from an empty folder with `env -i`).

- **Max/Ultra review fixes (2026-11-03; 3354750..597fbf7)**, from an adversarial review of the flows:
  - `PhaseFlow` tracks background forks by child id (`forks`); build waits for them; the turn end that finishes verify
    adds a Done note. Research needs one finished report and none still running (refused/failed don't count).
  - Second task: a message after done goes to the decider (job `flow`, `new_task`); a new task restarts the flow
    (`restart()`, new `run` id, approved plan cleared). Ultra workers are `research-<run>-N`, tracked per run.
    Max ↔ Ultra mid-flow keeps the phase (`withUltra`). A user message resets nudges.
  - Gates: `apply_patch` checked per file (harness `patchPaths`, app `writeTargets`); MCP asks before the plan even in
    Full auto (`decideAll(askMcp:)`); report fences defused.
  - Long runs: unreported background forks re-watched after restart (`unreportedBackground`); Ultra workflow 6 at once,
    45 min timeout, fallback angles, failed workflow → stuck until the user writes; Ultra cap on credits too; phase
    note after compaction and at the step cap.
  - Quick builds: decider `build_now` jumps to build (`buildingUnplanned`); present_plan allowed from questions; prose
    answers move questions on; research prompt sees model prices and sizes small tasks small.
  - Planning: gh reads are read-only; `isPlanningShell` (git fetch/pull --ff-only, curl/wget to stdout, tool
    inspection) runs before the plan and asks in Plan mode.
  - Bug fix: verify passes when the marker is gone / exit 0 / only another failure remains; repro snapshot only the
    tests the repro touches; `bug_check review` asks `SessionSpec.reviewModel` (another vendor) with
    `bugReviewSystem`. `/btw` uses the session's model.
  - 747 flutter tests pass, analyze clean. Not live-tested; no controller-level test of the Ultra queue/timeout.

- **Multi-harness run 1: foundations (2026-11-04; merge e721343, then 6d0d528).** Plan `~/.claude/plans/multi-harness.md`,
  notes `docs/research/batches/multi-harness/run1/`. `features/code/drivers/`: `HarnessDriver` (info, caps, detect,
  models), `driver_policy.dart` fallbacks, `driver_registry.dart` (everyai, claude-code and gemini need consent, codex,
  opencode, acp:<cmd>, terminal:<cmd>; the outside ones are stubs until run 2), `driver_process` (EVERYAI_SESSION,
  driver roots in the process table, `closeAllDriverProcesses`), `json_rpc.dart`, `event_journal.dart`,
  `UsageReport` (plan usage in `UsageTotals.planMicros`), `SessionSpec.briefing`; replay kit
  `test/support/replay_transport.dart`. `features/code/host/`: a loopback MCP server, with tokens per session, idle
  expiry, and `HostTools` (not wired yet). `drivers/briefing/`: skill export per session, `sessionBriefing`, and
  recipes for each CLI. 832 tests pass.

- **Multi-harness run 2: drivers + Stage 2 (2026-11-04; PR #1, merge aa8baa5).** Notes in
  `docs/research/batches/multi-harness/run2/`. Drivers: `drivers/acp/` (Gemini `--acp`, `opencode acp`, `acp:<cmd>`),
  `drivers/opencode/` (`opencode serve`), `drivers/codex/` (`codex app-server`; fixtures derived from the schema and
  marked unverified), `drivers/claude/` (`claude -p` stream-json, approvals via a host permission tool),
  `drivers/terminal/` (pty paste). A repo's own CLI config can't switch approvals off; no tokens on disk.
  `AttachesBriefed`: a reopened outside session gets a fresh host token and the old one is revoked; child sessions
  reopen without a briefing. Stage 2: lead + model at session start, per-CLI consent (Claude Code and Gemini off by
  default), briefing, `HostTools` on the controller, fidelity label, Settings → Code → Harnesses. Max/Ultra/Bug fix
  show "Coming later" on outside leads. 1023 tests pass. Nothing has run live: no real turn through any driver, Codex
  isn't installed, Gemini sign-in is untested. Open nits: ACP reopen drops the user's MCP servers; a race in the Claude
  rebrief while it spawns (not reachable today).
- **Multi-harness run 3, no-spend handoff (2026-11-04; branch `batch/mh-3`, 609f9d1).** Owner: EveryAI spends nothing
  on a session it doesn't lead. The handoff (`code/handoff/`) has no utility-model summary any more (old stored JSON
  with one still loads). It is facts plus the whole conversation as `.everyai/handoffs/<stem>.md` (git-excluded),
  which the new lead may read. A turn the usage limit cut off (`cutTurn`: the last real request with no finished reply
  before the limit; carry-ons count as the same turn) goes over as `<cut-turn>` with its calls and results, and the
  new lead finishes it. Gated on outside leads (`domain/no_spend.dart`): `/btw`, `/goal` and `/learn` are refused
  with a reason; `/commit` and `/pr` drafts are written without a model; no decide risk label (`riskLabelDir`). Audit
  in `docs/research/batches/multi-harness/run3/no-spend.md` (untracked). Not live-tested.
- **Dev deployment 0.1.0-dev-nonsigned (2026-11-04).** Anole 0.5.1. Backend live at
  `https://everyai.136-108-68-64.sslip.io:8443` on the `ttt-server` VM (GCP `ttt-ultimate-b7097a`, us-east1-b, e2-micro,
  shared with the owner's ttt stack: never touch its containers or `/opt/ttt` beyond the one Caddy block). Details:
  `backend-exp/deploy/README.md`; redeploy with `backend-exp/deploy/deploy.sh`.
  - Dev build: `DEV_AUTH=true` (no sign-in), **no server keys** (BYOK or local models only; the image holds only the
    binary), SQLite in the `everyai_data` volume. New config: `TLS_CERT_PATH`/`TLS_KEY_PATH` (Anole serves HTTPS
    itself; SIGHUP reloads) and `RATE_LIMIT_PER_MINUTE` (600 per client address, its own `global_limiter`).
  - TLS: ttt's Caddy owns 80/443 and only obtains/renews the cert (a site block that serves nothing); the container
    mounts Caddy's cert folder read-only; `everyai-cert-reload.timer` sends SIGHUP daily. Port 8443 via firewall rule
    `everyai-api` (network tag `everyai-api`). Caddyfile backup: `/opt/ttt/Caddyfile.bak-everyai`.
  - App: `ApiClient(waitForServer:)` holds requests until `GET /v1/ping` answers (90 s, backoff), shell banner "Waking
    up the EveryAI server…" (`serverStatusProvider`). `scripts/launch.sh` runs or builds the app against the server
    (detects the OS; web, ios-sim, ios, android, `build <target>`); `Launch Flutter (macOS).command` builds and opens
    the macOS app. Windows/Linux builds: `.github/workflows/dev-builds.yml` (push `builds/*` or run it by hand).
  - Entry screen (`features/onboarding/`): a five-step tour shown once per `appVersion` (`core/config/version.dart`,
    kept equal to pubspec by a test): welcome, expect bugs (GitHub issue link with the version), add a key (live
    `keyCheckProvider`, rejected keys not saved), Code agents found here (`driverStatusesProvider`, consent buttons;
    remote-control text off desktop), accept the Dev Build Terms (`TERMS-DEV.md`, same text as `devBuildTerms`).
    Headlines type themselves out (`TypewriterText`). Gate: `onboardingAcceptedProvider` in the shell.
  - Unsigned macOS Release: `keychain-access-groups` removed from `Release.entitlements` (needs a team); add it back
    for the signed release. macOS shows the version as 0.1.0 (Flutter drops the pre-release part there).
- **Signed releases (2026-11-04, commit "Signed releases…").** macOS: `frontend/macos/scripts/release_macos.sh`
  (Developer ID re-sign inside out, Deno with JIT entitlements, embedded Developer ID profile for
  `keychain-access-groups` via `Runner/DeveloperID.entitlements`, DMG, notarytool, staple, spctl); `asc.py` renews the
  profile (expires 2027-12-05). Windows: `msix_config` (Store identity `AliDirect.EveryAI`, 9PHCKCV3J9S9; the Store
  signs). `.github/workflows/release.yml` on `v*`: DMG + Store MSIX as a draft Partner Center submission + draft GitHub
  Release; secrets are set on the repo. Credentials and IDs: `TODO-deployment.md` → Credentials (local copies in
  `~/.applesigning/`). Verified: notarization accepted, stapled, the app from the DMG launches.
  Linux: `packaging/linux/package.sh` → AppImage + .deb (Deno next to the binary), SHA256SUMS, GPG `.asc` signatures
  (key `packaging/linux/everyai-release-key.asc`); release job on Ubuntu 22.04. Checked in an Ubuntu 22.04 container:
  the .deb installs, desktop file valid, signatures verify. Flathub is off the table (no AI-written manifests/PRs).
- **0.1.0-alpha.1, the first signed release (2026-11-05).** `-dev-nonsigned` dropped: pubspec `0.1.0-alpha.1+2`,
  `appVersion`, the terms, README (downloads → latest GitHub Release, the Microsoft Store listing 9PHCKCV3J9S9, the
  Homebrew tap `xuckless/homebrew-tap`), CHANGELOG. Tag `v0.1.0-alpha.1` runs `release.yml`. Dev builds stay unsigned
  (`0.1.0-alpha.1-unsigned`). Next versions: bump pubspec + `appVersion` together, tag `v<version>`.
- **In-app updates (2026-11-05).** `features/updates/`: each launch (`shell.dart`) and Settings → About ("Check now",
  "Get pre-releases", pref `updates.prereleases`) ask the GitHub releases API (`/releases/latest`, or the list with
  pre-releases on). By install (`data/install*.dart`): the signed macOS release → Sparkle 2.9 (`UpdaterBridge` in
  `macos/Runner/MainFlutterWindow.swift`, channel `everyai/updater`; only when signed by team 2MGLZ5685D; Dart passes
  that release's `appcast.xml`, Sparkle downloads quietly, holds the install; the sidebar's `UpdateBanner` "Restart to
  update" runs it, else it installs on quit). Linux AppImage → downloads beside `$APPIMAGE`, checks `SHA256SUMS.sig`
  (Ed25519) and the SHA-256, renames over itself, restarts. .deb → a download button. Store/dev builds → nothing.
  One Ed25519 key signs both: private `UPDATE_ED25519_KEY` (repo secret; owner copy
  `~/.applesigning/everyai/update_ed25519.key`), public in Info.plist `SUPublicEDKey` and `updates/update_key.dart`;
  `packaging/updates.py` (keygen/sign/appcast). `release.yml` adds `appcast.xml` and `SHA256SUMS.sig`.
  **Bump the pubspec build number (+N) every release**: Sparkle compares it. `EVERYAI_UPDATES_API` points the
  updater at another releases endpoint (testing). Verified on macOS with two locally signed builds (2 → 3): quiet
  download, install on quit, signature intact. The AppImage path is unit-tested only. Homebrew cask should say
  `auto_updates true`. Linux repos next: own signed apt/dnf repos on GitHub Pages, maybe COPR (the owner allows an
  `Assisted-by:` line there as a one-time exception), AUR pushed by the owner.

- **Prober fixes + 0.1.0-alpha.2 (2026-11-05; merge 2fe40cb, release 2713b25, PR #12).** Lane batch (6 items, notes
  `docs/research/batches/harness/prober-fixes/`): workflow agents get `workflowHostTools` (bug_check, check,
  diff_stats, memory read-only, report_issue) through a filtered host token; Bug fix proves with bug_check and asks for
  a thin bug (`workflows/bug_report.dart`); Ultra runs phases per item, `plan_ref` only from saved_plans; verdict-first
  results, merged lens findings, landing choice (commit here / new branch / leave); host `screenshot`, `browser`,
  `app_run` for outside leads (own apps free, others ask once); `<everyai-notice nonce>` wrapping; Claude Code skills
  off per project (`--settings skillOverrides`); approvals say why, scratch/temp writes free, sibling forks, mode
  inheritance. The bundled workflow tests need Deno (`frontend/.deno`); worktrees without it skip them (a parse error
  in security_review.js slipped through that way). Release: tag `v0.1.0-alpha.2` on main after the merge.
- **Security lives in the tools (2026-11-05; batch `batch/security-tools`, notes `docs/research/batches/security/`).**
  Owner: guardrails sit inside each tool (refuse, sanitise or warn in the result), never as approval cards, on in every
  mode incl. Bypass, for every lead. Base `core/security/untrusted.dart` (`untrusted()` wrapper, hidden-Unicode kinds;
  `keepWriting` keeps the joiners and direction marks real text needs; `untrustedRule`).
  - Harness tools: outside text wrapped (web_fetch/search, browser, network/repo commands, reads outside the project);
    the user's own files only stripped, and edits keep their hidden characters. `exfil.dart` refuses credential-store
    reads, uploads, gists, pushes to remotes not configured at start, drop sites and DNS exfil; the Scrubber hides
    secrets in output. URL/query leak checks are back on under Bypass (`bypass` only drops the research sandbox).
    Look-alike/punycode/typo domains (`official_sites`, also backend `net/official_sites.zig`); the browser never types
    into password/payment fields; screenshots skip password managers; package installs checked for typosquats and
    non-existent names (fail open offline); run_script bridge capped and guarded; red-team fixtures in `test/security/`.
  - `security_alert` tool and the owner's four checks in every lead's prompt or briefing (host MCP tool for outside
    leads): red transcript card, OS notification, `stop_run` decided by the model. Memory, plans, handoffs and fork
    reports are wrapped, and checked for smuggling on write.
  - Repos: EveryAI's git calls never run hooks, filters or fsmonitor; clone/open scan notes; MCP tool lists pinned by
    digest (changed tools left out until re-consent in Settings), shadowing flagged, results wrapped; skills, agents
    and commands scanned.
  - Chat: backend web tools wrapped and domain/leak-checked, the chat prompt has the checks, `security_alert` card;
    Markdown links carrying data show the host and warn; HTML/SVG sandbox verified.
  - Full flutter test (2308) and zig tests pass. Nothing live-tested. Open: whether Bypass keeps the session budget
    stop; the host browser's eval/type are unguarded for outside leads.

- **UI overhaul, phase 0 (2026-11-06; branch `ui-overhaul`, e935bb5).** Owner's plan and answers:
  `~/.claude/plans/ui-overhaul.md`; design: the claude.ai artifact "EveryAI" (boards per surface, `project/everyai.css`).
  One EveryAI look on every OS: the design-language picker is gone (Settings > Appearance has Pure black instead),
  one Material root supplies only plumbing. Tokens in `EveryTheme` (kit roles, dark/light/Pure black), Geist + Geist
  Mono bundled, Lucide icons, `core/motion/motion.dart` (the owner's 20 motion rules; entrances without timers;
  `Motion.ambient` is off under test via `test/flutter_test_config.dart`), `core/ui/kit.dart` widgets; the `Adaptive*`
  wrappers render the kit. Screens still use their old (Material-branch) layouts until their phase. Not checked
  visually yet. Next: phase 1 shell + sidebar, then Chat, Code session, Board, Settings, the rest.
- **UI overhaul, phases 1–3 (2026-11-06; 6bfa00f, d318a74, then phase 3).** Shell + sidebar (264pt, inset content
  panel, phone drawer, Chat|Code segmented), Chat on the kit (model chip with vendor monogram + effort in its popover,
  mode chip, round send/stop, quiet follow-ups, violet inline code), Code session: composer chips row (mode, Workflow
  named after the pick, Skills) with harness · model · effort under the box (MCP chip gone, it lives in Settings),
  `KitTabs` (one sliding underline) for the right panel (Session · Diff · Files) and the drawer (Terminal · Processes ·
  Preview), kit status dots and shimmer.
- **UI overhaul, phase 3b (2026-11-06).** Owner: the session panel has five tabs (Session · Diff · Preview · Files ·
  Processes; `ConsoleView`), the bottom drawer keeps only the Terminal (`CodePane.terminal`; an old saved drawer tab
  opens the terminal). Preview stays built once shown. New session page: random headline (`startWords`), the box, and
  one quiet line under it (harness · model · effort · cap · In place/Worktree · where it runs · settings gear; the
  explanations moved into the popovers' subtitles); `QuietTrigger` in the kit; a picked workflow also shows a removable
  chip above the field.
- **UI overhaul, phase 4: Board (2026-11-06).** `/code/board` (desktop; sidebar "Board" under New session),
  `features/code/board/`: Needs you / Running / Done columns (`BoardColumn.of(status)`), harness filter (segmented,
  only with 2+ harnesses), "This computer" host label, New session button. Cards: harness monogram
  (`harnessMark`), title, project · branch/worktree/fork, age, one live activity line (`boardActivity`, only for
  sessions with an open controller), Approve/Deny in place for approvals (pulse), Open/Answer for questions (answering
  happens in the session). Forks show once detached (`boardDetachedProvider`, prefs `code.board.detached`; toggle in
  the child chat header). Removed-harness sessions stay off. Not done: cards don't glide between columns; questions
  aren't answered on the card.
- **Board and list fixes (2026-11-06).** Board: Done cards clear (× on hover, Clear on the column; prefs
  `code.board.dismissed`; a cleared session that runs again comes back), cards glide to their new column (`_Glide`,
  one GlobalKey per card, ease-in-out with a shallow arc), hairline dividers resize the columns (prefs
  `code.board.columns`, double-click evens), questions are answered on the card (the `QuestionCard`; waiting sessions
  are opened so their card can answer). Closed sessions show what they last did: `ReadsRecentEvents` on the EveryAI
  harness, Claude Code and ACP drivers reads the tail of their event file (`readEventTail`); Codex and OpenCode keep
  no file, so they show status only. `KitListEditor` (`core/ui/list_editor.dart`): macOS Login Items-style table with
  + / − and Delete, replacing comma/line-separated inputs for research sites (dialog + Settings), Rules, and MCP
  environment variables and headers (secret-looking values hidden).
- **UI overhaul, phase 5: Settings (2026-11-06).** The modal follows the artifact's Settings board: a solid surface
  (r18, pop shadow, hairline on top) that eases in from 0.95; the left column (bg fill, 232pt) holds search and the
  sections under quiet group labels, with one highlight that slides to the open section (`_SlidingSelection`); the
  right side has the section title (StateSwap) and Close. Phones get grouped cards of sections, and a section slides
  in from the right with a back control. `KitGroupedList` (adaptive.dart) folds a page's flat children into
  `KitGroup` cards: runs of rows (`AdaptiveListTile`, `MenuRow`, or a `KitRowLike` such as `SettingsAnchor` around a
  tile) share a card, an `AdaptiveSectionHeader` labels the next card, anything else stands alone. Every settings
  page uses it. General: theme as three pictures (`ThemeCards`), Pure black (motion follows the system
  setting; no app switch). Account: avatar, name, email · plan, Manage
  plan. Code settings rows are quiet cards instead of ruled rows. Group headings in the list have a fine rule and
  a chevron that folds the group (prefs `settings.collapsed_groups`).
- **Window chrome on Windows/Linux (2026-11-06).** `core/platform/window_caption.dart`: the native title bar is
  hidden (`TitleBarStyle.hidden`, window_manager) and the app draws its own. `WindowButtonsOverlay` (app root
  builder) floats minimize / maximize-restore / close at the top right above every route and dialog (Windows: flat
  46pt cells, red close; Linux: small round buttons); `WindowCaption` is the 36pt drag strip (double-click
  maximizes) each layout keeps under them: the shell above the content panel beside the sidebar, and
  `WithWindowCaption` around sign-in, onboarding and the full-window Settings. `WindowResizeEdges` adds resize
  handles (all edges on Linux, top on Windows). Native: the Windows runner paints the app background and sets
  `DWMWA_BORDER_COLOR` to none; the Linux runner paints the GTK window #07070A. Not built or seen on Windows or
  Linux yet (widget tests only). macOS unchanged.
  Fix (2026-11-06, from a Fedora screenshot): the wide layout gave the panel no top padding, so the strip and the
  buttons sat on the panel's header (covering its icons, nothing free to drag). The panel now starts
  `windowCaptionHeight` down; the sidebar's title row is a `WindowDragArea` too. Test: `window_caption_test.dart`
  (headroom on Windows and Linux, via `ShellSplitView`).
- **UI overhaul, phase 6 (second pass), in steps (2026-11-06).** 6a onboarding: the board's layout (48pt top row with
  the mark and version, one 480pt column with five progress pills, headline, body, then Back · Later · Continue).
  The key step is the board's: provider switch across the column, one field with an inline ✓/✕ and Check, and a
  status line (hint, shimmering Checking, works, or rejected with nothing saved).
  6b model shop: one table (model with mark, vendor and capability line · context · price per M "in · out" ·
  Add/Added with a pulse, "…" options on hover), a search, scope chips (All, My models, Free, On your keys), the six
  biggest vendors plus More, and capability toggles (Tools, Vision, Reasoning, Makes images); rows re-enter staggered
  when the filters change. Narrow widths fold the price under the name. Negative catalog prices (routers) show none.
  6c cards: the question card has `KitTabs` (now with a `leading` mark: breathing dot for the current question, a
  tick once answered) and "n of m", "Pick one/any", option rows with their number key, a pencil "Other" row, panes
  that slide in from the side you move to, and Back · "n left" · Next / Submit ⌘↵. The plan card has "n steps · m
  files", a dot per step with its files flush right (steps settle in), "Switches to Auto-edit", Keep planning,
  Start building.
  6d usage/billing: "This month" card (mono "$x of $y", a thin bar that fills in, plan · left, wallet), per-key rows
  with a share bar and mono cost; billing uses the same bar and mono amounts.
  6e MCP / Skills / Agents: one-line intros instead of paragraphs, skill and agent names in mono with one-line
  descriptions, the Claude Code skills list on a card (`KitGroupedList.fold`).
  6f Remote: host and device sections on cards, a status dot by the relay state, the security code in mono on the
  right, Remove this host in red. Artifacts page and the inline renderers (flashcards, slides, quiz) already sat on
  the kit; left as they are.
  6g workflow progress (Session tab's running work): a thin bar per run (finished agents), status dots on workflow
  agents and background commands, commands in mono. Not seen with a live Ultra run.
- **Logos back (2026-11-06).** Owner: real icons for every model vendor, harness and editor, from Lobe Icons (MIT,
  owner's pick; notice added), brand colour on a tile. `core/ui/logos.dart`: `Logo.vendor(slug)` / `.harness(id)` /
  `.app(id)` map to `assets/logos/*.svg` (51 files); `LogoTile` draws a neutral tile (r 28%, hairline), `-color` files
  keep their colours, one-colour marks take the text colour; no logo → the old monogram (`AgentGlyph`). EveryAI uses
  the brand mark. `ModelAvatar` (shop, pickers, composer chip, message footer, Settings) and `HarnessLogo`
  (`code/ui/harness_logo.dart`: Board cards, agent menu, Code composer line, harness rows in Settings/onboarding with
  the status as a corner dot, Code home's Earlier list) use it; the API keys page too. Kimi uses the one-colour mark
  (its colour K vanishes on dark). Missing in Lobe Icons: VS Code, Augment, Factory, Zed, TeleAI, Writer and other
  small vendors (monograms). The old rasters in `assets/models/` are unused now.
- **Reopens where it was closed (2026-11-06).** `app/router.dart`: every route change that `restorableLocation`
  accepts (a chat, Code home, a Code session, the Board, Chats/Projects/Artifacts/Models; not sign-in or Settings) is
  saved in Preferences `app.last_location`; the first router of a run starts there (`restoredLocation`; a removed Code
  session falls back to `/code`; an `INITIAL_LOCATION` define still wins). Checked with a hot restart from the Board.
- **Code sidebar (2026-11-06).** Project headings fold like Settings groups (name + chevron, hairline underneath,
  Preferences `code.sidebar.folded`; searching shows all), with the session rows' insets so the ⋯ lines up. Each
  session row starts with its harness's logo (`SessionStatusIcon(status, harness)`); its state is a dot on the
  logo's corner (none when idle/done).
  A project's ⋯ has New session: `Routes.newCodeSession(id)` = `/code?project=<id>`, read by `CodeHome(projectId:)`
  (also on `didUpdateWidget`). The Code session panel opens at a third of the session screen (`consolePanelShare`
  0.33 via `PanelSplit.defaultShare`; artifacts keep 0.52); sessions with a dragged width keep it, double-click
  resets. Code home's earlier EveryAI sessions name their harness beside its logo.
- **Plan report card (2026-11-06).** An outside lead's `/usage` text (the cost aside) is parsed by
  `code/domain/plan_report.dart` (`parsePlanReport`: notes, limits `X: N% used · resets …`, headings + caption,
  periods `Last 24h · …`, shares `N%  text · detail`, `Top …: a N%, …`; anything else stays a note) and drawn by
  `ui/transcript/plan_report_view.dart` (limit bars amber ≥75%, red ≥90%; share rows; pills). All-notes text falls
  back to mono. Fixed: the fill of every animated bar (usage, billing, workflow runs) had zero height.
- **Terminal tabs, glyphs, Code home terminal (2026-11-06).** The terminal falls back to the bundled Nerd Fonts
  Symbols font (`ui/panes/terminal_font.dart`), so Powerline/Nerd Font prompts draw. `TerminalTabsView(owner,
  workingDir)` has tabs with + and × (`terminalTabsProvider`; the first tab's id is the owner's, so Processes/Preview
  keep reading it; others `<owner>#<n>`, `EVERYAI_TERMINAL` stays the session id). Code home has a purple Terminal
  chip in the top bar opening a resizable bottom terminal (owner `home`, starts in `terminalHomeDir`: `$HOME`, or
  `C:\` on Windows; prefs `code.home.terminal`, `code.home.terminal_height`). Session header icons got a 2pt gap so
  two open views' highlights don't merge.
- **UI audit, onboarding once, What's new (2026-11-07; branch `ui-audit`).** The surfaces built since the overhaul
  (Processes, Preview and its device views, terminal tabs, real-input consent, local models, the setup terminals, chat's
  no-model card) checked against the UI rules: sentence-case `KitLabel` headers instead of ALL CAPS, `KitCard`,
  `showKitDialog` + `theme.shadowPop` instead of hand-made backdrops/shadows, `Motion` curves, shorter copy. Device
  bezels keep their fixed dark colour on purpose. Onboarding is done once (`onboarding.accepted` holds the version it was
  accepted in; any value counts). After an update, `features/updates/`: `releaseNotes` (`domain/whats_new.dart`, empty
  until a release adds its entry) → `whatsNewProvider` shows this build's notes once at launch (`whats_new.seen`; a
  fresh install marks them seen on accepting the onboarding) in `ui/whats_new_dialog.dart` (KitDialog 520pt, scrolls,
  wraps long lines); Settings → About has "What's new" when the build has notes.
- **Shells (2026-11-06; branch `toolbuild`, 02828ac..5e018bc; plan and owner answers in `TODO-toolbuild.md`).**
  `code/shells/`: `ShellRegistry.instance` holds a `ShellEntry` per command the EveryAI harness runs (foreground
  `cmd_N`, background `bg_N`) and for app_run's app; raw output in `<session dir>/shells/<id>.log` (`ShellLog`,
  10 MB then rolled to `.1`), live chunks with byte offsets (`entry.output`, synchronous) so a tab replays the log
  and follows without gaps. Background shells run in a pty (`pty_spawn_io.dart`; pipes when flutter_pty doesn't load,
  e.g. `flutter test`), env `ptyShellEnv` (colour, PAGER=cat, GIT_TERMINAL_PROMPT=0). Model view: `cleanTerminalText`.
  Tool `bash_input {shell_id, text, keys}` (kind `ShellInputAction`, asks like a command); bash_output/monitor add
  "user typed …", "restarted", "seems to wait for input" (`waitingFor`, `looksLikePrompt`). Processes tab groups
  processes under their shell (`groupByShell`), opens `shellTabId` tabs (Stop/Restart/Copy/Send to agent, scrubbed),
  lists Docker/Podman containers (`containers.dart`: compose dir, bind mount, or ids the session's docker commands
  printed) with logs/shell-inside tabs (`TerminalTabs.addCommand`), and tails the stdout file of processes EveryAI
  didn't start (`outputFileOf`).
- **Live web Preview (2026-11-06; d2b72c7).** `code/live/`: `ChromeHost.of(profileDir)` runs one headless Chrome per
  project profile (`browserProfileDir`, App Support `browser-profiles/<sha1>`), `HeadlessBrowser` takes a page target
  in it; `LiveBrowsers.forSession(codeSessionId)` is the page the EveryAI harness (`SessionSpec.liveId`/
  `browserProfile`), the host browser tool and `PreviewPane` all use. The page outlives runs; released on session
  remove, all stopped at quit. Preview paints `Page.startScreencast` (first picture captured at start), forwards input
  unguarded (`userMouse/userKey/userText`), `LiveControl` = driver lock (user input takes over, agent actions wait 2
  min, `gaveBackText`), ghost cursor from `control.activity`. Agent API: `FrameBook` frame ids (`f_N`, geometry check,
  zoom regions), `pageSnapshotJs` element list with `ref_N`, `evalRefusal` (cookies/storage/other-site requests),
  eval results scrubbed. Chrome for Testing download pinned in `live/chrome_pin.dart` by
  `tool/pin_chrome_for_testing.sh`. Dev MCP test rig: `tool/live_mcp/live_mcp_serve_test.dart` (env
  `EVERYAI_LIVE_MCP_OUT`) serves the host browser tool + a demo shop for an outside agent to review.
- **Framework sources: the `app` tool (2026-11-06).** `live/app_endpoints.dart` finds apps in a shell's output
  (`flutter run`'s VM service line, Chromium's `DevTools listening on` for Electron, Metro's banner);
  `AppSources.running(sessions)` scans the sessions' registry shells (and an outside lead's output files via
  `scanOutputFile`) and holds one driver per app. Drivers: `FlutterApp` (`live/flutter_app_io.dart`, VM service
  JSON-RPC: `ensureSemantics` + one evaluated expression for the semantics tree with global rects, semantics
  tap/setText, pointer events, inspector screenshots, `s<N>.reloadSources`/`hotRestart`, Stdout/Logging/Flutter.Error
  log; expressions must be one line), `ReactNativeApp` (`live/react_native_io.dart`, Metro `/json/list` → CDP;
  `reactNativeTreeJs` walks fibers through `__REACT_DEVTOOLS_GLOBAL_HOOK__` and calls onPress/onChangeText; reload via
  `Page.reload` or POST `/reload`), Electron = `HeadlessBrowser.attached(endpoint)` (the browser tool on the app's
  own window). Tool spec `live/app_tool_spec.dart`, work in `harness/everyai/app_tools_io.dart` (`runAppTool`):
  EveryAI harness `app` (kind `AppAction`, read-only except eval) and host MCP `app` (`ScreenAccess.app`). Results say
  what changed on screen (`appTreeChange`); app text goes in an `untrusted` block. `bash_output {screen: true}`
  renders a TUI's screen (`shells/terminal_screen.dart`, headless xterm). Preview: source chips (Web + each app),
  Flutter picture view (polled inspector shots, taps/wheel forwarded), RN element list, Electron live page. Verified
  against a running `flutter run -d flutter-tester` app (`tool/live_apps/flutter_app_probe_test.dart`,
  `EVERYAI_FLUTTER_VM`); Electron and RN paths tested with Chrome standing in (`app_sources_test.dart`); no real
  Electron or React Native app was run.
- **iOS Simulator (2026-11-06).** The `app` tool's source "ios" drives a booted simulator for any app (native,
  Flutter, React Native) through AXe (`live/ios_simulator_io.dart`): `describe-ui` → `AppNode`s (points; refs `iN`
  stable by type+label+id; keyboard keys folded into "(the on-screen keyboard is up)"), tap/long_press/type (⌘A, then
  `type --stdin`, value checked; never into SecureTextField)/scroll/drag as swipes, back (the nav bar's back button,
  else an edge swipe, which AXe's touches don't always trigger), home, screenshots + zoom with frame ids, and
  actions `devices` / `boot {device}`. A simulator counts for a session when its shells name it (udid, `on iPhone 16
  in debug mode`, `-d "iPhone 16"`) or it booted it; `IosSimulators.claim` lets one session drive it at a time. AXe
  1.8.0 is downloaded on first use into app data `tools/axe-1.8.0/` and checked against `axe_pin.dart`
  (`verified_download_io.dart`, shared with Chrome for Testing; `EVERYAI_AXE` overrides). Preview: `IosSimulatorView`
  paints `axe stream-video` MJPEG (~9 fps at half scale, `MjpegFrames` cuts by Content-Length), forwards clicks,
  drags and the wheel. Dev probe `tool/live_apps/simulator_probe_test.dart` (`EVERYAI_SIM`).
- **Android (2026-11-06).** The `app` tool's source "android" drives an emulator or device for any app through adb
  (`live/android_device_io.dart`, `live/adb_io.dart` finds the SDK: ANDROID_HOME/ANDROID_SDK_ROOT, the usual folders,
  PATH, `EVERYAI_ADB`; nothing downloaded): `uiautomator dump` → `AppNode`s in pixels (refs `aN`; a clickable
  container named by its children's text, which isn't listed again), `input` tap/swipe/keyevent/text (Ctrl+A first so
  type replaces; non-ASCII pasted through scrcpy), back (says when it only closed the keyboard), home, `screencap`
  pictures, `install` (.apk) / `launch` (package, fresh), `logs` = logcat of the app in front (`*:I`, stacks folded,
  `trimLogcat`). `devices` lists iOS sims, adb devices and AVDs; `boot` starts an AVD headless. iOS and Android share
  `DeviceScreen` / `DeviceHolds` (`live/device_screen.dart`) and one branch in `app_tools_io.dart` (`_device`). Each
  action reads the tree once before (`_fresh` reuses it) and once after; a uiautomator dump takes ~2 s.
  Preview: `AndroidDeviceView` runs the scrcpy 5.0.1 server (`live/scrcpy_io.dart`, our client of its v5 protocol;
  the server file is downloaded on first use and checked, `scrcpy_pin.dart`, `EVERYAI_SCRCPY_SERVER` overrides; it
  deletes itself on exit, so it is pushed every start) and decodes its H.264 with VideoToolbox into a Flutter texture
  (`VideoDecoderBridge` / `H264Texture` in `macos/Runner/MainFlutterWindow.swift`, channel `everyai/h264`,
  `live/h264_texture.dart`); other OSes get screenshots each second. Touches, drags, the wheel and the keyboard go
  through scrcpy's control socket. Checked in a real macOS build with `tool/live_apps/device_view_demo.dart` (both
  device views; a tap sent through the view opened the app). Dev probe `tool/live_apps/android_probe_test.dart`
  (`EVERYAI_ANDROID`).
- **Desktop windows (2026-11-06).** The `app` tool's source "desktop" (macOS) drives the windows of apps the session
  started (its shells' process trees; outside leads: the pids the host passes) or built in the project
  (`live/desktop_window_io.dart`). Through `everyai-ax`, our own Swift helper (`tool/ax_helper/main.swift`; dev build
  `tool/build_ax_helper.sh` → `frontend/.tools/`, `EVERYAI_AX_HELPER` overrides; the macOS build compiles it into
  `Contents/Resources` from `macos/scripts/bundle_ax_helper.sh`, called by `bundle_deno.sh`; release signing covers
  it). **Accessibility first**: tap = AXPress (an entry inside a table/list row selects the row: `show` + `select`),
  type = set the value (never into secure fields), scroll = the scroll bar, long_press = AXShowMenu. **Then the real
  pointer and keyboard** (owner, 2026-11-07) for what AX can't do: taps at a point with nothing pressable (Tk, games,
  canvases), elements with no press, fields that ignore set-value, `key`, drag, the wheel. The helper's `--front`
  makes the app frontmost (not again when it already is, which would close Tk's pop-up lists) and posts to the HID
  tap. Gate `live/real_input.dart` `RealInput`: asked once by a dialog (`ui/real_input_consent.dart`,
  `connectRealInput` in the shell), remembered in prefs `code.desktop.real_input` ('1'/'0'), switch in Settings >
  Code (Global, "Driving apps"); no dialog (tests, rigs) = no, `EVERYAI_REAL_INPUT=1|0` overrides. Pictures (`shot`)
  include the app's pop-ups and dialogs over the window; the Preview stream shows the window alone. Verified on the
  futoshiki copy: Load through the native panel, AC-3 picked from Tk's pop-up list, solved, Timeout typed (Tk has no
  Cmd+A: `tap {count: 3}` triple-clicks to select; the real-typing fallback does too). New `key` action on iOS (AXe HID codes) and Android (keyevents/keycombination) via
  `DeviceScreen.key`.
  Guards (security pass, 2026-11-07; light on purpose): the helper's real input waits (≤8 s) while the user is using
  the mouse or keyboard (exit 8), sends a pointer event only where the app's own window or pop-up is on top (not the
  menu bar, another app, or outside its windows; exit 7), and keys only while the app is frontmost and macOS secure
  input (a focused password field) is off. `key` won't type text while a password field has the focus
  (`secretFocusRefusal`; iOS shows no focus, so there a password field on screen is enough). Discovery skips
  password managers (`sensitiveWindow`). A DevTools address the agent names (`source`/`list` with ws://…) must
  listen in one of the session's processes or a program built in the project (`_foreignDevTools`, lsof), so a user's
  own browser with remote debugging isn't attached.
  Preview `DesktopWindowView`: the live stream; clicks press through AX, else a real click (same consent); Bring to
  front. Probe
  `tool/live_apps/desktop_probe_test.dart` (`EVERYAI_DESKTOP_PID`); the MCP rig takes `EVERYAI_LIVE_WINDOW_MATCH`.
- **Desktop windows on Windows and Linux (2026-11-07).** Same `desktop` source and driver; the helper differs
  (`live/desktop_helper_io.dart` `desktopHelper()`: same commands and JSON as everyai-ax, sources in
  `assets/helpers/`, installed under app data `tools/` named by content hash; `EVERYAI_DESKTOP_HELPER` overrides).
  - **Windows** `everyai_win.cs`: compiled on first use by the .NET Framework 4 `csc.exe` every Windows has (keep it
    **C# 5**), UI Automation tree in AX role names (paths start with the HWND; ListItem/DataItem/TreeItem = AXRow),
    actions via Invoke/Toggle/SelectionItem/ExpandCollapse/RangeValue/ScrollPattern/Value, PrintWindow pictures with
    the app's pop-ups composited, SendInput real input with the same guards (idle via GetLastInputInfo,
    WindowFromPoint root owner, foreground pid, focused UIA element not a password), `procs` (Toolhelp) feeds
    `_descendants` on Windows. Compile-checked only (`tool/desktop_helpers/check_windows_compiles.sh`, .NET SDK);
    **never run on Windows**.
  - **Linux** `everyai_x11.py`: python3 + ctypes Xlib/XTest/XRes (no packages), no accessibility tree yet (pictures
    and coordinates), keys by name (spare keycode borrowed for characters the map lacks), PNG frames for the stream.
    Each session gets its own **Xvfb** (`live/nested_display_io.dart` `NestedDisplays`, `-displayfd`, 1440×900, when
    Xvfb is installed and `EVERYAI_NESTED_DISPLAY` isn't 0): `SessionShell` adds DISPLAY (+ GDK/QT/SDL/Electron X11
    hints, WAYLAND_DISPLAY removed; `withNestedDisplay`) so the session's apps open there; every window there is the
    session's; input there needs no consent or guards (`--nested`). Without Xvfb: the user's display, pid/exe
    ownership, consent and guards as on macOS. Stopped on session remove and at quit. Verified in an Ubuntu 22.04
    container (`tool/desktop_helpers/check_linux.sh`: Tk app, clicks, typing "Hello Wörld €", Enter, wheel, guard);
    the Dart side wasn't run on Linux.
- **Real-project testing (2026-11-06).** Outside agents drove the owner's projects through the MCP rig (copies or
  read-only runs; no project files touched): pixl-playroom (Electron, 6/10 → 8/10 after the browser fixes in
  3387f20), tranzit (Expo; its dev build isn't installed and can't be built here because its gitignored
  `ios/.xcode.env.local` points NODE_BINARY at a removed Homebrew node; owner to rebuild), futoshiki (Tk, desktop
  windows: 6/10 with front-posted clicks, before the switch to accessibility only). RN fixes from it: Metro's usual address is tried for "react-native", `list` says whether an app is
  connected to Metro, `launch` says when the app isn't installed, simulator names on several iOS versions need
  "(iOS 18.6)".
- **Local models (2026-11-06; branch `local-models`, plan `~/.claude/plans/local-models.md`).** Owner: Ollama first,
  auto-detect the rest, Chat and Code, Apple FM the macOS chat default, a clear "Chat needs a model", harnesses work
  without keys, one-click packs from a spec scan.
  - Bundled server (`core/local_backend/`): backend-exp in `LOCAL_MODE` (loopback, `X-EveryAI-Local` token, nothing
    charged), built by `frontend/tool/build_local_backend.sh` (macOS arm64+x86_64, Windows/Linux cross), bundled by the
    macOS build phase, the Linux packages and the Windows MSIX job. `SplitTransport` sends local-model and own-key chat
    turns to it, credit turns to the deployed server. Headers `X-Local-*` / `X-Local-Aux-*` / `X-Search-*`: see
    backend-exp/README.md "Local mode"; keyless search is DuckDuckGo HTML.
  - `features/local_models/`: servers (Ollama, `fm serve`, LM Studio, llama.cpp, Jan, vLLM, MLX, manual), hardware
    scan per OS, packs (`assets/local_models.json`, refreshed from GitHub main), Ollama pulls, Settings → Local models,
    `showLocalModelSetup`. `local_model_bridge.dart` turns them into `local/<name>` catalog specs and
    `LocalRoutes.current` (read per call by the Code harness's `GatewayClient`, which calls local servers directly);
    detection is off in tests (`localDetectionProvider`).
  - Defaults: Apple's model for new chats when present; with no key, the smallest local model (Chat) and a coding
    model (Code). Light harness profile for local models with a window of 32K or less. The EveryAI lead greys out with
    no model; new sessions then start on a ready outside agent.
  - Not live-tested: no Ollama here, the fm licence isn't agreed, Windows/Linux packages not built.
- **0.1.0-alpha.5 and the web app (2026-11-07; PR #28, tag `v0.1.0-alpha.5`).** Release of PRs #23–#27 (UI
  overhaul, local models, the tool buildout, the UI audit). `releaseNotes` in `features/updates/domain/whats_new.dart`
  got its first entry (8 items); add one with every version bump. alpha.4 was never published (its draft release
  stays a draft and the cask stayed on alpha.3), so the alpha.5 release notes carry alpha.4's changes too.
  - **Web app live at `https://app.everyai.dev`** (Chat + remote control; the computer still runs Code sessions):
    `flutter build web --release --wasm` with the launch defines (dev server, `DEV_SKIP_AUTH`), served as Cloudflare
    Workers static assets (worker `everyai-web`, zone `everyai.dev` on the owner's Cloudflare account, SPA fallback,
    `_headers` with nosniff, frame DENY, COOP). Redeploy steps in `TODO-deployment.md` §2. Every visitor is the
    dev backend's `dev-user` until real sign-in lands.
  - **Web build fix (PR #29):** #26 made `shell_io.dart` import `shells/pty_spawn_io.dart` (flutter_pty →
    `dart:ffi`), which the web build reaches through `code_providers → live_browsers → browser_io → shell_io`.
    Now a conditional import with `pty_spawn_stub.dart` (no pty on the web; pipes instead).

## Next steps
Updated 2026-11-07. The owner's working lists are the TODO files (gitignored); the task board is the GitHub Project.
1. **Live testing** (the biggest gap): one real turn per outside driver (Claude Code, Codex, OpenCode, Gemini/ACP),
   a handoff, a resume and a workflow; local models on a real Ollama; the `app` tool on real projects; a real pass
   on Windows and Linux machines (desktop windows there are 3–4/10). `TODO-multi-harness.md` "Still open",
   `TODO-toolbuild.md`.
2. **Tool buildout follow-ups** (`TODO-toolbuild.md`; PR #26 lists them by value): outside-agent re-runs, speed of
   desktop/Android actions, iOS refs, Preview pop-out, Annotate, device frames.
3. **Distribution** (`TODO-deployment.md`): the backend on its own domain and off the shared ttt VM, real sign-in,
   the curl installer and apt/dnf repos on Cloudflare R2, web deploys from CI, then Android (Play closed test + APK)
   and iOS (Sign in with Apple, TestFlight).
4. **Then** (`TODO-multi-harness.md`, `TODO-harness.md`): the standalone package, Lead Mode, live terminal views, the
   OS sandbox and headless mode, local models for outside harnesses.

## Gotchas
- Format Dart with `dart format -l 120 <files>` (the project's width). Plain
  `dart format lib` rewraps every file to 80 columns.
- Zig 0.17: `**` array repetition is gone (use `@splat` + concat);
  `std.ArrayList` is unmanaged; handlers need `(*App, *anole.Request)`
  params even when unused.
- Anole `testing.Response.json(T)` takes no allocator; the test client type is
  `anole.testing.Client(anole.Server(App))`.
- `anole.client(req).fetch(url, .{.method = .post, .headers = &.{.{k,v}},
  .body})` is the convenience client. The core `http.fetch` is for streaming
  (`.stream = true`).
- OpenRouter: with native web search, citations are nondeterministic; `exa`
  always cites (~$0.007/search). The usage chunk comes last, before
  `[DONE]`; `: OPENROUTER PROCESSING` comments occur.
- The old FastAPI backend (`backend/`) was removed on 2026-11-05; backend-exp is the only server.
- **The web build:** anything reaching `dart:ffi` (flutter_pty, ffi packages) must sit behind a conditional import
  (`… if (dart.library.ffi) '…_io.dart'`); `dart:io` compiles on the web but `dart:ffi` doesn't. Run
  `flutter build web --wasm` after touching imports in `features/code/` (#26 broke it unnoticed).
- **Every release:** bump pubspec (+N), `appVersion`, TERMS-DEV.md, the README badge, docs/ROADMAP.md, dev-builds.yml,
  add a CHANGELOG section and a `releaseNotes` entry; tag `v<version>` on main; then publish the draft release and
  bump the Homebrew cask (they don't happen by themselves).
