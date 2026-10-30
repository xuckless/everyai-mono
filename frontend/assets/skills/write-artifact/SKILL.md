---
name: write-artifact
description: Decide when and how to use create_artifact for documents, code files and HTML pages. Use when the user wants something substantial to keep, edit or download, such as a report, essay, README, script, landing page or small web app.
license: Apache-2.0
metadata:
  tool: create_artifact
---
# Writing artifacts

An artifact is for content the user will keep, edit or download. Short answers, explanations and snippets stay in the chat.

## Choosing the kind
- `markdown`: reports, essays, letters, study notes, plans, READMEs. Figures go inside the document, never as separate artifacts.
- `code`: one source file. Set `language`. Give complete, runnable code with imports, not fragments with "..." gaps.
- `html`: one self-contained page. Inline the CSS and JavaScript. Load libraries only from the allowed CDNs (cdn.jsdelivr.net, cdnjs.cloudflare.com, unpkg.com). No placeholder URLs or images that do not exist; draw with CSS or inline SVG.
- `svg`, `mermaid`, `drawing`: see the vector-art and draw-diagram skills.

## Documents
- Start with a title and a two-sentence summary, then headings that tell the reader where to look.
- Use short paragraphs, real lists and tables for comparisons. Number steps that happen in order.
- Cite sources the user gave you. Mark anything uncertain instead of smoothing it over.
- Use a stable, short kebab-case `id` (for example `q3-report`) and keep it for the life of the chat.

## HTML pages
- Make it responsive: a viewport meta tag, relative units, and a layout that works at 360 px wide.
- Respect light and dark with `prefers-color-scheme`. Keep contrast readable.
- Give interactive controls labels and keyboard access. Avoid alerts and external requests.

## Code
- Match the user's language, style and library choices. Add comments only where the reason is not obvious.
- Say in the chat how to run it, in one or two lines.

## Changing an artifact
Use `edit_artifact` with small exact replacements for fixes and rewording. Create a new artifact only when the user wants a different deliverable. Never recreate an artifact just to change a line.
