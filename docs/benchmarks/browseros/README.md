# BrowserOS benchmark: results across models

One task, one prompt, several models and companies, on the EveryAI Code harness (plus one OpenHands baseline). Each folder has a full stat sheet in `results.md`. Costs are what EveryAI charged (upstream ×1.15), including side calls.

**Task:** Browser OS in one file (HTML/CSS/JS, opens in Chrome): at least 5 apps; two FUNCTIONAL 3D games (one a GTA clone, one creative); procedurally generated moving wallpapers; a Messages app with 5 recent messages sent to other AI models; one documented "special" feature.

| Run | Model | Effort | Tier | Harness | Charged | Cache hit | Wall | Calls | Tools /10 | Result (review) /10 | Result (owner) /10 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| [sonnet-browseros-efficient](sonnet-browseros-efficient/results.md) | `anthropic/claude-sonnet-5.5` (Anthropic) | medium | Efficient | EveryAI | $1.550 | 91.5% | 10.4 min | 15 | 7 | 7.5 | **7** |
| [sonnet-browseros-thorough](sonnet-browseros-thorough/results.md) | `anthropic/claude-sonnet-5.5` | medium | Labelled **Thorough** | EveryAI | $3.399 | 94.8% | 23.8 min | 28 | 8 | 8.5 | **9** |
| [terra-browseros-max](terra-browseros-max/results.md) | `openai/gpt-6.1-terra` | medium | Max | EveryAI | $0.952 | 91.3% | 4 h 09 min | 126 | 5 | 7.5 | **6** |
| [kimi-browseros-max](kimi-browseros-max/results.md) | `moonshotai/kimi-k2.6` | medium | Max | EveryAI | $1.438 | 92.9% | 14.0 min | 120 | 5 | 6.5 | **5** |
| [deepseek-flash-browseros-medium--max](deepseek-flash-browseros-medium--max/results.md) | `~deepseek/deepseek-flash-latest` | medium | Max | EveryAI | $1.480 | 95.7% | 23.2 min | 561 | 9 | 8.5 | **9** |
| [open-hands-impl-sonnet-medium](open-hands-impl-sonnet-medium/results.md) | `anthropic/claude-sonnet-5.5` | medium | Efficient | OpenHands agent-server | $7.778 | 12.6% | 29.2 min | 34 | 6 | 7 | **9** |

## Takeaways
- **Best value:** DeepSeek Flash on Max scored 9/10 for $1.48, with the cleanest fork orchestration (4 parallel builders + a build script) and a 95.7% cache hit rate.
- **Best single-agent run:** Sonnet 5.5 (labelled Thorough, run with Efficient rules) scored 9/10 for $3.40, fully offline.
- **Caching is the cost story:** every EveryAI run hit 91–96% cached; the OpenHands baseline hit 12.6% and cost $7.78.
- **Harness bugs found:** the Max plan phase didn't advance on approval (Terra); forks tried to fork (Kimi, DeepSeek); a run could end with no final report (Kimi).
- **Brief drift:** Kimi and DeepSeek pulled three.js from a CDN, and Terra made the AI messages "fictional examples".
- Not included: the Gemini 3.8 Flash Max run (its folder was removed) and the killed Kimi high-effort attempt (summarised in the Kimi sheet).
