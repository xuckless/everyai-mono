---
name: draw-diagram
description: Write clear Mermaid diagrams with the render_diagram tool. Use when the user asks for a flowchart, sequence diagram, state machine, class or ER diagram, timeline, mind map or any process or architecture picture.
license: Apache-2.0
metadata:
  tool: render_diagram
---
# Drawing diagrams

Call `render_diagram` with Mermaid source and a short `title`. Output only the diagram source in the tool, with no code fences.

## Pick the type
- Steps and decisions: `flowchart TD` (or `LR` for wide, linear flows).
- Messages between parties over time: `sequenceDiagram`.
- Lifecycles: `stateDiagram-v2`.
- Data models: `erDiagram`. Object structure: `classDiagram`.
- Schedules and history: `timeline` or `gantt`. Ideas around a topic: `mindmap`.

## Keep it readable
- Aim for 5 to 15 nodes. If it needs more, split it into two diagrams or group parts in a `subgraph`.
- Use short node labels (2 to 5 words). Put detail in the chat, not the box.
- Give nodes simple ids (`auth`, `db`) and write the label in brackets: `auth[Sign in]`.
- Label edges only when the meaning is not obvious: `a -->|yes| b`.
- Flow in one main direction. Avoid crossing lines by ordering nodes along the flow.
- Decisions are diamonds with two or more labeled exits.

## Avoid syntax errors
- Wrap any label containing parentheses, quotes, colons, slashes or `#` in double quotes: `n1["Retry (max 3)"]`.
- Do not use the word `end` alone as a node id; write `End` or `finish`.
- Avoid HTML in labels, and avoid special characters in ids.
- Do not add custom colors unless asked; the viewer picks a theme for light and dark.

## Afterwards
Explain the diagram in one or two sentences and offer the obvious next view (for example the failure path). If the user wants to restyle or move it, resend the full corrected source.
