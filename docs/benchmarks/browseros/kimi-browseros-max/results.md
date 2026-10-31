# Moonshot Kimi K2.6 · medium effort · Max

> EveryAI harness stat sheet · BrowserOS benchmark · recorded 2026-10-31 from the session transcripts (`everyai-sessions/`, agent-server events) and the backend ledger (`usage_events`).

## Run card

| Field | Value |
|---|---|
| Model | `moonshotai/kimi-k2.6` |
| Company | Moonshot AI |
| Effort | medium (an earlier **high**-effort attempt was killed; see below) |
| Tier | Max |
| Harness | EveryAI |
| Mode | Full auto |
| Upstream | OpenRouter |
| Date | 2026-10-31 01:02–01:16 |
| Session | `01a19056-9312-71c4-b130-85172881712f` |
| Status | Finished **without a final report** (last messages were mid-fix on a glitch overlay) |

**Task:** Browser OS in one file (HTML/CSS/JS, opens in Chrome): at least 5 apps; two FUNCTIONAL 3D games (one a GTA clone, one creative); procedurally generated moving wallpapers; a Messages app with 5 recent messages sent to other AI models; one documented "special" feature.

## Scores

| Metric | Score | Who |
|---|---|---|
| Tool usage | **5/10** | harness review (transcript) |
| Result (reviewer) | 6.5/10 | harness review (load test + report) |
| **Result (owner)** | **5/10** | owner, hands-on |

## Cost

| Line | Calls | Upstream cost | Charged (×1.15) |
|---|---|---|---|
| kimi-k2.6 (main + forks) | 102 | $1.107 | $1.273 |
| google/gemini-3.5-flash-lite (titles, side jobs) | 18 | $0.144 | $0.165 |
| **Total** | 120 | **$1.251** | **$1.438** |

## Tokens and caching (main model)

| Prompt | Completion | Cache reads | Cache writes | Cache hit rate |
|---|---|---|---|---|
| 4,574,958 | 87,438 | 4,252,064 | 0 | **92.9%** |

Cost per 1K completion tokens: $0.013 upstream.

## Time

| Wall clock | Active (est.) | Model calls / active min |
|---|---|---|
| 14.0 min | ~13 min | ~7.8 |

## Tool calls (orchestrator / main session)

| Tool | Calls |
|---|---|
| `browser` | 43 |
| `read` | 8 |
| `edit` | 5 |
| `write` | 4 |
| `check_forks` | 4 |
| `run_subagent` | 3 |
| `bash` | 3 |
| `stop_fork` | 2 |
| `todo_write` | 2 |
| `monitor` | 1 |
| `ask_user_question` | 1 |
| `present_plan` | 1 |
| **Total** | **77** |

- Tool errors: **2**
- Calls refused by the harness (phase gates, held calls): **11**
- Provider / conversation errors: **0**

## Forks

| Fork | Role | Time | Tool calls | Errors | Outcome |
|---|---|---|---|---|---|
| Research procedural wallpaper | researcher | 2.9 min | 20 | 5 (tried to fork 3×, check_forks 1×, fetch 1×) | 166-line report |
| Research Three.js single-file 3D games | researcher | 1.4 min | 16 | 1 bash | Report; recommended three.js via CDN |
| Research browser OS patterns | researcher | 1.9 min | 23 | 6 (tried to fork 3×, fetch 2×, write 1×) | Report |

## Deliverable

| Field | Value |
|---|---|
| File | `index.html` (61.0 KB), "Win95 Browser OS" |
| Apps | 7 icons: Messages, Robin City (GTA), Abyss Diver, Terminal, Music, Calculator, Settings |
| 3D tech | three.js r160 ES modules **from unpkg.com** |
| External dependencies | **Yes**: needs internet for three.js |
| Load test (headless Chrome, 2026-10-31) | BIOS boot screen, then the Win95 desktop; 0 console errors at load |

## Requirement checklist

| Requirement | Status |
|---|---|
| ≥5 apps | ✅ 7 |
| GTA clone, 3D, functional | ❓ Robin City (not verified hands-on by the harness) |
| Creative 3D game | ❓ Abyss Diver |
| Procedural moving wallpaper | ✅ gradient field |
| Messages: 5 to other AIs | ✅ |
| Special feature documented | ⚠️ "Glitch" mode; no final write-up |
| Single file, opens in Chrome | ⚠️ single file, but needs the CDN |

## Comments

- **Earlier attempt, high effort (killed by the owner):** session `01a1900a`, 2026-10-30 23:40–23:58 (17.8 min), 116 Kimi calls (4.73M prompt, 92.1% cached), $1.771 + $0.247 side calls charged. It was spending minutes on single huge writes and on screenshot hacks, and it killed the owner's Chrome. Those findings drove the write-in-parts, browser tool and pkill-floor changes. **Total spend on this folder: $3.46.**
- This medium run was much healthier: 43 `browser` calls of real click-through verification, and it used `check_forks`/`stop_fork` to manage its researchers.
- Researchers tried to start their own forks 6 times (refused, since forks can't fork), and `monitor` was pointed at a shell that didn't exist.
- It ended without a final report, so the user gets no feature list or controls. The run "finished" while still describing a fix in progress.
- It ignored the self-contained intent: three.js comes from unpkg, so the OS breaks offline.
- The cache worked well (92.9%), but Kimi writes 0 cache-write tokens (provider-side caching), so the hit rate depends on OpenRouter routing.
