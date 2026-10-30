---
name: make-deck
description: Plan and write a slide deck with the make_slides tool. Use when the user asks for a presentation, slides, a pitch or a talk outline, or wants a document turned into a deck.
license: Apache-2.0
metadata:
  tool: make_slides
---
# Making a deck

Call `make_slides` once with the whole deck. Do not paste the slides into the chat as well; say in a sentence what the deck covers.

## Plan first
1. Pin down the audience, the length of the talk and the one thing they should remember. If the request leaves these open, pick sensible defaults rather than asking.
2. Write the storyline as a list of slide titles before writing any slide. The titles alone should read as the argument.
3. Aim for 6 to 12 slides for a short talk, and one slide per minute at most for a longer one.

## Each slide
- The title states the point ("Churn fell 18% after onboarding changes"), not the topic ("Churn").
- Use `bullets` for 3 to 5 short items, each under about 12 words. Use `body` (Markdown) only for a table, a short quote or a few lines of code that bullets cannot carry.
- One idea per slide. Split a slide that needs more than five bullets.
- Put the detail, sources and the words you would say in `notes`, written as speaker notes someone could read aloud.
- Do not invent numbers. If a figure is an estimate, say so on the slide.

## Shape of the deck
- Open with a title slide (the tool's `title` and `subtitle`), then a slide that frames the problem or the question.
- Close with a clear next step or decision, not "Thank you" or "Questions?".
- Keep wording and structure parallel from slide to slide.

## Theme
`light` suits most rooms and print. `dark` suits a dim room and demos. `navy` suits a formal or financial tone. `minimal` suits text-light, design-led talks. Choose one and keep it; do not mix.

## Revising
When the user asks for changes, call `make_slides` again with the full updated deck rather than describing edits.
