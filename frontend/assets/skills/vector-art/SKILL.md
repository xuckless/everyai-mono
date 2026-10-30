---
name: vector-art
description: Design and draw SVG illustrations with the render_svg tool, using a design brief, a style preset and stable layer ids. Use when the user wants an icon, logo mark, figure, sketch, scene or other vector drawing, or a revision of one.
license: Apache-2.0
metadata:
  tool: render_svg
---
# Vector art

## Brief before pixels
Write down, privately, before drawing:
1. Subject and the one thing the viewer should recognize first.
2. Mood, and a palette of 3 to 5 hex colors: a dominant, an accent, a dark and a light.
3. The layers from back to front.

## Choose a style
Set the tool's `style` when the user's wording points to one.
- `flat`: bold simple shapes, at most four colors, no outlines. Good default for illustrations.
- `line_icon`: a regular grid, one stroke width, round caps, one accent. For icons and pictograms.
- `isometric`: 30 degree axes and three shades per solid. For objects, rooms and systems.
- `geometric_logo`: a few circles, squares and arcs on a clear grid. For marks and badges; keep it legible at 32 px.
- `hand_drawn`: slightly irregular strokes and soft fills. For informal sketches.
- `poster`: strong composition, large shapes, limited type. For covers and banners.
Read the rules that come back with the result and fix the drawing if it breaks them.

## Build it
- Root `<svg>` has `xmlns` and a fixed `viewBox` (for example `0 0 512 512`), and no pixel width or height.
- Document order is paint order: background, large shapes, mid-ground, details, highlights.
- Group each layer as `<g id="sky">`, `<g id="body">` and give key shapes meaningful ids. These ids are how later edits target a part, so keep them when you revise and never rename them without a reason.
- Prefer primitives and short paths. Use `<defs>` for gradients and clip paths. Keep one stroke width and one corner radius.
- No scripts, external images, fonts or links. Avoid `<text>` unless a label is the point.

## Check
Every part is attached to its neighbor, nothing is hidden behind a same-colored shape, there is no white on white, proportions are believable, and the picture reads at 64 px.

## Revising
For a small change, use `edit_artifact` against the layer's id if the drawing was made as an artifact; otherwise resend the whole SVG with the same ids and layer order.
