# Claude Sonnet 5.5 · medium effort · Efficient

> EveryAI harness stat sheet · BrowserOS benchmark · recorded 2026-10-31 from the session transcripts (`everyai-sessions/`, agent-server events) and the backend ledger (`usage_events`).

## Run card

| Field | Value |
|---|---|
| Model | `anthropic/claude-sonnet-5.5` (Anthropic) |
| Company | Anthropic |
| Effort | medium |
| Tier | Efficient |
| Harness | EveryAI |
| Mode | Full auto |
| Upstream | Anthropic API (native adapter) |
| Date | 2026-10-30 17:13–17:24 |
| Session | `01a18ea8-d9ca-7fe2-b8bf-fb9c98bdd6f8` |
| Status | Finished with a final report |

**Task:** Browser OS in one file (HTML/CSS/JS, opens in Chrome): at least 5 apps; two FUNCTIONAL 3D games (one a GTA clone, one creative); procedurally generated moving wallpapers; a Messages app with 5 recent messages sent to other AI models; one documented "special" feature.

## Scores

| Metric | Score | Who |
|---|---|---|
| Tool usage | **7/10** | harness review (transcript) |
| Result (reviewer) | 7.5/10 | harness review (load test + report) |
| **Result (owner)** | **7/10** | owner, hands-on |

## Cost

| Line | Calls | Upstream cost | Charged (×1.15) |
|---|---|---|---|
| claude-sonnet-5.5 (main) | 15 | $1.348 | $1.550 |
| **Total** | 15 | **$1.348** | **$1.550** |

## Tokens and caching (main model)

| Prompt | Completion | Cache reads | Cache writes | Cache hit rate |
|---|---|---|---|---|
| 1,248,420 | 81,775 | 1,141,747 | 101,285 | **91.5%** |

Cost per 1K completion tokens: $0.016 upstream.

## Time

| Wall clock | Active (est.) | Model calls / active min |
|---|---|---|
| 10.4 min | ~10 min (no waits) | 1.5 |

## Tool calls (orchestrator / main session)

| Tool | Calls |
|---|---|
| `bash` | 8 |
| `read` | 7 |
| `edit` | 3 |
| `write` | 1 |
| **Total** | **19** |

- Tool errors: **3**
- Calls refused by the harness (phase gates, held calls): **0**
- Provider / conversation errors: **0**

## Deliverable

| Field | Value |
|---|---|
| File | `index.html` (61.8 KB), "AuroraOS" |
| Apps | 8: Street Theft 3D, Neon Glider, Messages, Notes, Calculator, Terminal, Wallpaper, Pulse |
| 3D tech | Canvas 2D software renderer (no WebGL) |
| External dependencies | None (fully offline) |
| Load test (headless Chrome, 2026-10-31) | Loads, 0 console errors, Messages window open at start |

## Requirement checklist

| Requirement | Status |
|---|---|
| ≥5 apps | ✅ 8 |
| GTA clone, 3D, functional | ✅ Street Theft 3D (steal cars, wanted stars, police, jobs) |
| Creative 3D game | ✅ Neon Glider |
| Procedural moving wallpaper | ✅ |
| Messages: 5 to other AIs | ✅ Claude, ChatGPT, Gemini, Llama 3, DeepSeek |
| Special feature documented | ✅ Pulse |
| Single file, opens in Chrome | ✅ |

## Comments

- Cheapest and fastest complete run; 15 model calls for a full 8-app OS.
- Wrote the whole file in one `write`, then patched it with edits. That is the pattern the new append rule replaces.
- Verified in headless Chrome by script (drove a car into a wall). It tried Playwright first (not installed) and used BSD-incompatible `sed -i`, then switched to Python: two wasted calls.
- One edit was refused as stale ("changed since you read it") after a script rewrote the file. The guard worked as designed.
- "3D" is a hand-rolled Canvas-2D projector: it meets the letter of the brief, but the visuals are the weakest of the Sonnet runs.
