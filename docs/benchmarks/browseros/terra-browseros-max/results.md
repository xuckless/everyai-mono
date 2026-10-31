# OpenAI GPT-6.1 Terra · medium effort · Max

> EveryAI harness stat sheet · BrowserOS benchmark · recorded 2026-10-31 from the session transcripts (`everyai-sessions/`, agent-server events) and the backend ledger (`usage_events`).

## Run card

| Field | Value |
|---|---|
| Model | `openai/gpt-6.1-terra` |
| Company | OpenAI |
| Effort | medium |
| Tier | Max (research → questions → plan → build → verify) |
| Harness | EveryAI |
| Mode | Full auto |
| Upstream | OpenRouter |
| Date | 2026-10-30 20:57 → 2026-10-31 01:06 |
| Session | `01a18f75-c2a4-7b9f-a3fe-72685c2245b4` |
| Project folder at run time | `gemma-browserOS-thourough` (renamed afterwards) |
| Status | Finished with a short final report |

**Task:** Browser OS in one file (HTML/CSS/JS, opens in Chrome): at least 5 apps; two FUNCTIONAL 3D games (one a GTA clone, one creative); procedurally generated moving wallpapers; a Messages app with 5 recent messages sent to other AI models; one documented "special" feature.

## Scores

| Metric | Score | Who |
|---|---|---|
| Tool usage | **5/10** | harness review (transcript) |
| Result (reviewer) | 7.5/10 | harness review (load test + report) |
| **Result (owner)** | **6/10** | owner, hands-on |

## Cost

| Line | Calls | Upstream cost | Charged (×1.15) |
|---|---|---|---|
| gpt-6.1-terra (main + forks) | 105 | $0.661 | $0.760 |
| google/gemini-3.5-flash-lite (titles, side jobs) | 21 | $0.167 | $0.192 |
| **Total** | 126 | **$0.827** | **$0.952** |

## Tokens and caching (main model)

| Prompt | Completion | Cache reads | Cache writes | Cache hit rate |
|---|---|---|---|---|
| 2,988,261 | 40,132 | 2,729,279 | 258,383 | **91.3%** |

Cost per 1K completion tokens: $0.016 upstream.

## Time

| Wall clock | Active (est.) | Model calls / active min |
|---|---|---|
| 4 h 09 min | ~15–20 min | ~6 |

The wall clock is mostly idle time: the run waited on the owner ("retry", "continue") while stuck in the plan phase. The forks took 0.2–3.9 min each.

## Tool calls (orchestrator / main session)

| Tool | Calls |
|---|---|
| `read` | 13 |
| `bash` | 13 |
| `edit` | 8 |
| `glob` | 7 |
| `present_plan` | 7 |
| `run_subagent` | 5 |
| `grep` | 5 |
| `todo_write` | 4 |
| `write` | 3 |
| `present_files` | 2 |
| `ask_user_question` | 1 |
| `monitor` | 1 |
| `kill_shell` | 1 |
| **Total** | **70** |

- Tool errors: **5**
- Calls refused by the harness (phase gates, held calls): **13**
- Provider / conversation errors: **3**

## Forks

| Fork | Role | Time | Tool calls | Errors | Outcome |
|---|---|---|---|---|---|
| Research desktop interaction patterns | researcher | 0.4 min | 15 (4 search, 11 fetch) | 0 | Single file, Pointer Events, Canvas wallpaper |
| Research self-contained 3D games | researcher | 0.4 min | 13 | 1 fetch | Shared tiny WebGL renderer recommended |
| Build two 3D games | builder | 3.1 min | 16 | 0 | `games.js`, not wired in |
| Build desktop and utilities | builder | 3.9 min | 16 | 0 | `index.html` shell, 6 launchers |
| Review game integration risks | reviewer (Plan mode) | 0.2 min | 5 reads | 0 | Caught "games never initialized": the integration bug |

## Deliverable

| Field | Value |
|---|---|
| File | `index.html` (55.1 KB), "ORBIT — a little world of your own" |
| Apps | 6: Vice City, Sky Courier, Messages, Notes, Wallpaper Studio, Home |
| 3D tech | Canvas 2D (no WebGL context, despite the researcher's WebGL recommendation) |
| External dependencies | None |
| Load test (headless Chrome, 2026-10-31) | Loads, 0 console errors; the most polished visual design of the set |

## Requirement checklist

| Requirement | Status |
|---|---|
| ≥5 apps | ✅ 6 |
| GTA clone, 3D, functional | ⚠️ "GTA-inspired driving sandbox", Canvas-2D 3D |
| Creative 3D game | ⚠️ Sky Courier, Canvas-2D 3D |
| Procedural moving wallpaper | ✅ Wallpaper Studio (seeded, special feature) |
| Messages: 5 to other AIs | ⚠️ "clearly labeled fictional example prompts", which softens the brief |
| Special feature documented | ✅ Wallpaper Studio |
| Single file, opens in Chrome | ✅ |

## Comments

- **Harness bug surfaced here:** the Max flow stuck at the plan phase 4 times. `present_plan` was called 7× and "The plan is approved" was sent 5×, but the flow didn't advance, so writes and bash were refused 13×. The owner had to nudge it ("retry", "continue"). This is the main reason for the low tool score, and most of the blame is the harness's, not the model's.
- 3 "Provider returned error" failures at the very start (OpenRouter); the retry layer did not exist yet.
- Fork use was textbook: two fast researchers, two parallel builders, and a Plan-mode reviewer that found the real integration bug (games never initialized) before the merge.
- Cheapest Max run: $0.95 total, with a 91.3% cache hit rate and very terse output (40K completion tokens over 105 calls).
- The final report is thin (no feature list, no controls, no known gaps), and the Messages content dodges the brief.
- Owner 6/10: it looks great but plays weakest (Canvas-2D 3D, light games).
