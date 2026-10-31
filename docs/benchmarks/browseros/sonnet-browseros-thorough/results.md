# Claude Sonnet 5.5 · medium effort · Thorough (recorded as Efficient)

> EveryAI harness stat sheet · BrowserOS benchmark · recorded 2026-10-31 from the session transcripts (`everyai-sessions/`, agent-server events) and the backend ledger (`usage_events`).

## Run card

| Field | Value |
|---|---|
| Model | `anthropic/claude-sonnet-5.5` |
| Company | Anthropic |
| Effort | medium |
| Tier | Labelled **Thorough**; the session record says `efficient`, and the system prompt had no tier block (see comments) |
| Harness | EveryAI |
| Mode | Full auto |
| Upstream | Anthropic API (native adapter) |
| Date | 2026-10-30 17:33–17:57 |
| Session | `01a18ebb-22a2-7d0f-a67f-8f474e5ef24f` |
| Status | Finished with a final report |

**Task:** Browser OS in one file (HTML/CSS/JS, opens in Chrome): at least 5 apps; two FUNCTIONAL 3D games (one a GTA clone, one creative); procedurally generated moving wallpapers; a Messages app with 5 recent messages sent to other AI models; one documented "special" feature.

## Scores

| Metric | Score | Who |
|---|---|---|
| Tool usage | **8/10** | harness review (transcript) |
| Result (reviewer) | 8.5/10 | harness review (load test + report) |
| **Result (owner)** | **9/10** | owner, hands-on |

## Cost

| Line | Calls | Upstream cost | Charged (×1.15) |
|---|---|---|---|
| claude-sonnet-5.5 (main) | 28 | $2.955 | $3.399 |
| **Total** | 28 | **$2.955** | **$3.399** |

## Tokens and caching (main model)

| Prompt | Completion | Cache reads | Cache writes | Cache hit rate |
|---|---|---|---|---|
| 4,018,626 | 175,511 | 3,807,708 | 198,813 | **94.8%** |

Cost per 1K completion tokens: $0.017 upstream.

## Time

| Wall clock | Active (est.) | Model calls / active min |
|---|---|---|
| 23.8 min | ~23 min (no waits) | 1.2 |

## Tool calls (orchestrator / main session)

| Tool | Calls |
|---|---|
| `bash` | 18 |
| `write` | 8 |
| `read` | 8 |
| `present_files` | 1 |
| **Total** | **35** |

- Tool errors: **3**
- Calls refused by the harness (phase gates, held calls): **0**
- Provider / conversation errors: **0**

## Deliverable

| Field | Value |
|---|---|
| File | `aura-os.html` (144.7 KB), "AuraOS" |
| Apps | 8: Terminal, Notes, Messages, Calculator, Settings, Aura, Neon City, Pocket Planet |
| 3D tech | WebGL2 |
| External dependencies | None (fully offline) |
| Load test (headless Chrome, 2026-10-31) | Loads, 0 console errors, animated nebula wallpaper, dock + desktop icons |

## Requirement checklist

| Requirement | Status |
|---|---|
| ≥5 apps | ✅ 8 |
| GTA clone, 3D, functional | ✅ Neon City (drive, wanted level) |
| Creative 3D game | ✅ Pocket Planet |
| Procedural moving wallpaper | ✅ 4 generators |
| Messages: 5 to other AIs | ✅ ChatGPT, Gemini, Claude, Llama 3, Mistral |
| Special feature documented | ✅ Aura |
| Single file, opens in Chrome | ✅ (needs WebGL2) |

## Comments

- Owner's pick among the Sonnet runs (9/10). It is the most complete offline single file.
- Built the file in 8 writes (parts), then concatenated. This is the behaviour the harness now asks every model for.
- Strongest self-verification of the Sonnet runs: screenshots of the desktop, apps, both games and three of the four wallpapers, plus about a minute of simulated game time per game. It said honestly that it never looked at the Nebula wallpaper.
- All 3 bash errors were its own path slips (`cd` into a missing scratch folder, a screenshot path that didn't exist). They cost no rework.
- **Tier caveat:** the run was labelled Thorough, but the session recorded `tier: efficient` and the system prompt carried no `<HARNESS_TIER>` block, so it ran with Efficient rules. The difference from the Efficient run is the model choosing to work longer, not the harness. Re-run on a real Thorough tier to compare.
- Cost was 2.2× the Efficient run for a clearly better result; the cache hit rate of 94.8% kept it at $3.40.
