# DeepSeek Flash (latest) · medium effort · Max

> EveryAI harness stat sheet · BrowserOS benchmark · recorded 2026-10-31 from the session transcripts (`everyai-sessions/`, agent-server events) and the backend ledger (`usage_events`).

## Run card

| Field | Value |
|---|---|
| Model | `~deepseek/deepseek-flash-latest` |
| Company | DeepSeek |
| Effort | medium |
| Tier | Max |
| Harness | EveryAI |
| Mode | Full auto |
| Upstream | OpenRouter |
| Date | 2026-10-31 01:26–01:50 |
| Session | `01a1906c-7af0-7657-9bbd-58f28e567061` |
| Status | Finished with a full final report |

**Task:** Browser OS in one file (HTML/CSS/JS, opens in Chrome): at least 5 apps; two FUNCTIONAL 3D games (one a GTA clone, one creative); procedurally generated moving wallpapers; a Messages app with 5 recent messages sent to other AI models; one documented "special" feature.

## Scores

| Metric | Score | Who |
|---|---|---|
| Tool usage | **9/10** | harness review (transcript) |
| Result (reviewer) | 8.5/10 | harness review (load test + report) |
| **Result (owner)** | **9/10** | owner, hands-on |

## Cost

| Line | Calls | Upstream cost | Charged (×1.15) |
|---|---|---|---|
| deepseek-flash-latest (main + forks) | 546 | $1.166 | $1.341 |
| google/gemini-3.5-flash-lite (titles, side jobs) | 15 | $0.121 | $0.139 |
| **Total** | 561 | **$1.287** | **$1.480** |

## Tokens and caching (main model)

| Prompt | Completion | Cache reads | Cache writes | Cache hit rate |
|---|---|---|---|---|
| 62,383,793 | 446,099 | 59,679,744 | 0 | **95.7%** |

Cost per 1K completion tokens: $0.003 upstream.

## Time

| Wall clock | Active (est.) | Model calls / active min |
|---|---|---|
| 23.2 min | ~23 min | ~23.5 (orchestrator + 6 forks in parallel) |

## Tool calls (orchestrator / main session)

| Tool | Calls |
|---|---|
| `browser` | 142 |
| `bash` | 61 |
| `edit` | 20 |
| `read` | 19 |
| `write` | 11 |
| `check_forks` | 7 |
| `run_subagent` | 6 |
| `ask_user_question` | 1 |
| `present_plan` | 1 |
| `present_files` | 1 |
| **Total** | **269** |

- Tool errors: **6**
- Calls refused by the harness (phase gates, held calls): **18**
- Provider / conversation errors: **0**

## Forks

| Fork | Role | Time | Tool calls | Errors | Outcome |
|---|---|---|---|---|---|
| Research single-file 3D in browser | researcher | 0.9 min | 24 | 3 fetch | No-build UMD three.js recommendation |
| Research procedural animated wallpapers | researcher | 1.4 min | 22 | 2 | One WebGL1 canvas, 30 fps cap |
| Build GTA clone game | builder (worktree) | 7.1 min | 56 | 2 | `src/game-gta.js`, 1,721 lines, verified |
| Build wallpaper engine | builder (worktree) | 9.8 min | 83 | 3 (tried to fork) | `src/wallpaper.js`, 704 lines |
| Build Gravity Slingshot game | builder (worktree) | 9.7 min | 69 | 0 | `src/game-slingshot.js`, 1,554 lines, levels solver-verified |
| Build OS utility apps | builder (worktree) | 4.7 min | 36 | 1 | `src/apps.js`, 1,720 lines |

## Deliverable

| Field | Value |
|---|---|
| File | `browser-os.html` (315.6 KB), "NEBULA OS", built from `src/` by `build.py`; `README.md` |
| Apps | Neon Vice (GTA), Slingshot, Messages, Files, Notes, Terminal, Settings, About |
| 3D tech | three.js r160 (UMD) + WebGL shader wallpapers |
| External dependencies | **Yes**: three.js from jsDelivr with an unpkg fallback (needs internet) |
| Load test (headless Chrome, 2026-10-31) | Loads; only a three.js deprecation warning; nebula shader wallpaper, dock, welcome toast |

## Requirement checklist

| Requirement | Status |
|---|---|
| ≥5 apps | ✅ 8 |
| GTA clone, 3D, functional | ✅ Neon Vice (157 buildings, traffic, on-foot, drift physics, deliveries, minimap) |
| Creative 3D game | ✅ Slingshot: gravity golf, 8 solver-verified levels |
| Procedural moving wallpaper | ✅ 5 shader generators, crossfade, parallax |
| Messages: 5 to other AIs | ✅ Claude, DeepSeek, GPT, Gemini, Qwen, with a working composer |
| Special feature documented | ✅ Desktop Time Machine (journaled window events, 15-min scrub) |
| Single file, opens in Chrome | ⚠️ single file, but three.js comes from a CDN |

## Comments

- **Best orchestration of the set.** Two researchers, then four builders in parallel on disjoint files against a written `CONTRACT.md`, then integration through a build script. This is exactly the shape the Max tier is designed for.
- 142 `browser` calls in the verify phase: the most thorough real click-through of any run.
- 546 model calls and 62.4M prompt tokens, but a **95.7% cache hit rate** and Flash pricing kept it at **$1.48 total**. That is the best result per dollar in the benchmark.
- 18 refusals were phase gates (bash before the plan was approved, etc.); it recovered from each without help.
- A few stale-edit refusals after forks were merged into `shell.js`/`style.css`; it re-read the files and carried on.
- The only miss against the brief is the CDN dependency for three.js (with a fallback, but it still needs a network).
- The project folder has an empty git repo (`main` has no commits): the orchestrator never committed the merged result.
