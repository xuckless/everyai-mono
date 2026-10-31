# Claude Sonnet 5.5 · medium effort · OpenHands harness (A/B baseline)

> EveryAI harness stat sheet · BrowserOS benchmark · recorded 2026-10-31 from the session transcripts (`everyai-sessions/`, agent-server events) and the backend ledger (`usage_events`).

## Run card

| Field | Value |
|---|---|
| Model | `anthropic/claude-sonnet-5.5` |
| Company | Anthropic |
| Effort | medium |
| Tier | Efficient |
| Harness | **OpenHands agent-server v1.59.0** (not EveryAI) |
| Mode | Full auto |
| Upstream | Anthropic API via the EveryAI gateway |
| Date | 2026-10-30 15:46–16:16 |
| Session | `01a18e59-813d-7ed6-bb65-8d8c2ad06d8b` (conversation `6c284a70…`) |
| Output location | `EveryAI/frontend/tool/agent_eval/browser_os/index.html` (see `path-inside-txt.textClipping`) |
| Status | **Stopped by the owner** at 29 min (a pending file edit was cancelled); no final report |

**Task:** Browser OS in one file (HTML/CSS/JS, opens in Chrome): at least 5 apps; two FUNCTIONAL 3D games (one a GTA clone, one creative); procedurally generated moving wallpapers; a Messages app with 5 recent messages sent to other AI models; one documented "special" feature.

## Scores

| Metric | Score | Who |
|---|---|---|
| Tool usage | **6/10** | harness review (transcript) |
| Result (reviewer) | 7/10 | harness review (load test + report) |
| **Result (owner)** | **9/10** | owner, hands-on |

## Cost

| Line | Calls | Upstream cost | Charged (×1.15) |
|---|---|---|---|
| claude-sonnet-5.5 (main) | 34 | $6.763 | $7.778 |
| **Total** | 34 | **$6.763** | **$7.778** |

## Tokens and caching (main model)

| Prompt | Completion | Cache reads | Cache writes | Cache hit rate |
|---|---|---|---|---|
| 2,940,004 | 156,623 | 369,923 | 40,011 | **12.6%** |

Cost per 1K completion tokens: $0.043 upstream.

## Time

| Wall clock | Active (est.) | Model calls / active min |
|---|---|---|
| 29.2 min | ~21–29 min | ~1.2 |

## Tool calls (orchestrator / main session)

| Tool | Calls |
|---|---|
| `terminal` | 24 |
| `file_editor` | 14 |
| **Total** | **38** |

- Tool errors: **1**
- Calls refused by the harness (phase gates, held calls): **1**
- Provider / conversation errors: **0**

## Deliverable

| Field | Value |
|---|---|
| File | `index.html` (75.1 KB), "AetherOS" |
| Apps | 9: Neon Streets, Stardust Hop, Messages, Notes, Terminal, Calculator, Sketchpad, Rewind, Settings |
| 3D tech | WebGL2 + Canvas 2D |
| External dependencies | None (fully offline) |
| Load test (headless Chrome, 2026-10-31) | Loads, 0 console errors, Messages window open at start |

## Requirement checklist

| Requirement | Status |
|---|---|
| ≥5 apps | ✅ 9 |
| GTA clone, 3D, functional | ✅ Neon Streets |
| Creative 3D game | ✅ Stardust Hop |
| Procedural moving wallpaper | ✅ |
| Messages: 5 to other AIs | ✅ ChatGPT, Claude, Gemini, Llama 3, Mistral |
| Special feature documented | ⚠️ Rewind app present; no final write-up (stopped) |
| Single file, opens in Chrome | ✅ |

## Comments

- **Most expensive run by far: $7.78**, because only **12.6%** of prompt tokens hit the cache. That run came before the gateway cache-breakpoint fix (3fda0fd); same model and task on the EveryAI harness cost $1.55–3.40 at 91–95% cache hits.
- One invalid tool call (`terminal` with `reset: true` and no command) failed OpenHands validation.
- The output quality is high (owner 9/10: 9 apps, offline, WebGL2), but it was stopped before it finished, so there is no final report or documented special feature.
- **Same-day EveryAI A/B partner** (session `01a18e5d`, "Old deprecated", 15:50–15:55): Sonnet 5.5 medium on the early EveryAI harness wrote `everyai-result.html` (43.9 KB, "PulseOS", 6 apps) in 5.3 min with 10 calls, $1.53 upstream / $1.76 charged, with **0% cache** (gateway caching was broken then). It finished with a report but couldn't view its own screenshot.
- Takeaway: OpenHands produced a richer file than the early EveryAI harness, at 4.4× the cost. Today's EveryAI harness (the Sonnet Thorough run) matches that quality at less than half the cost.
