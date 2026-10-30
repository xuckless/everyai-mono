# SVG eval

Twenty SVG prompts, five conditions, a render gate and a vision-model judge.
It decides which prompt version, engine and critique-round count we ship.
Design notes: `docs/research/vector-art.md` section 6. Not wired into
`flutter test`, and it spends money, so run it on purpose.

## Files

- `prompts.dart`: the 20 prompts (icons, logos, flat art, scenes, posters, diagrams, one edit turn) with a style preset each; `hard: true` marks the known-difficult ones (6, 10, 12, 15, 18, 19, 20).
- `conditions.dart`: the five conditions and the design brief and style presets, in our own wording.
  1. `baseline`: the request only.
  2. `brief`: design brief prepended (plan, then draw, then self-check).
  3. `brief_preset`: brief plus the prompt's style preset.
  4. `brief_polish`: brief plus preset, then one `POST /v1/figures/polish` round.
  5. `recraft`: `POST /v1/images {engine:"vector"}` (once per prompt, not per model).
- `gate.dart`: pulls the SVG out of the reply, checks structure (root `svg`, balanced tags, xmlns, viewBox, no script, foreignObject, image, event or external references) and, when `rsvg-convert` is on PATH, really rasterizes it. Install with `brew install librsvg`. Without it the gate is structural only and judging and polish are skipped.
- `judge.dart`: the rubric prompt (six 1-5 dimensions plus a defect list, JSON reply), a pairwise prompt with order-swap handling, parsing, per-condition summary, and the ship rule (+0.5 judge points at under 2x cost).
- `run.dart`: the runner.

## Run

```sh
cd frontend
# Dry run: prints the grid and a cost estimate, calls nothing.
dart run tool/svg_eval/run.dart

# Live. The backend must be running (DEV_AUTH=true, or pass --token sk-... / a JWT).
dart run tool/svg_eval/run.dart --live --models anthropic/claude-haiku-5.5 --samples 1 \
  --conditions baseline,brief --prompts 1,8,11
```

Options: `--models a,b` (generators for conditions 1-4), `--judge <model>` (use a
different vendor than the generator), `--samples N` (default 3), `--prompts`,
`--conditions` (by key), `--api` (default `http://127.0.0.1:8080`), `--out`
(default `build/svg_eval`, which receives the first sample's SVG per cell and
`summary.json`). Prompt 20 edits the output of prompt 8 under the same
condition, so run them together.

## Cost

Estimated by the dry run from per-call constants in `run.dart`
(about 9k micro-dollars per generation, 3.5k per judged image, 12k per polish,
40k per vector image). Full grid on one Haiku-class model with 3 samples:
20 prompts x 5 conditions x 3 = 300 cells, roughly $9. A smoke pass
(`--samples 1 --prompts 1,8,11 --conditions baseline,brief`) is about
$0.10. Three generator models for conditions 1-4 triples the LLM part. The
judge call is the second-largest term, so judge once per cell, not per sample
pair. Check real numbers against `GET /v1/usage/session/:id` for the printed
session.

## Reading results

`summary.json` has pass rate, mean judge score and mean cost per condition.
Apply the rule: ship the critique round if `brief_polish` gains 0.5 over
`brief_preset` at under twice the cost; ship the vector engine for the
illustration buckets if `recraft` beats the best LLM condition by 0.5. Spot-check
ten outputs by eye per release.

Known gaps: the gate rasterizes with librsvg, not flutter_svg, so renderer
differences show only in the app; objective metrics beyond bytes (path count is
computed by `checkStructure` but not yet summarized) and pairwise judging are
available as functions but not yet driven by the runner.
