import 'prompts.dart';

/// The five conditions compared by the eval.
enum Condition {
  /// The prompt as-is, no extra guidance.
  baseline,

  /// Plan-then-draw design brief prepended.
  brief,

  /// Brief plus the prompt's style preset.
  briefPreset,

  /// Brief plus preset, then one render-and-look polish round.
  briefPolish,

  /// The vector image engine (`/v1/images`, engine "vector").
  recraft;

  String get key => switch (this) {
    baseline => 'baseline',
    brief => 'brief',
    briefPreset => 'brief_preset',
    briefPolish => 'brief_polish',
    recraft => 'recraft',
  };

  bool get usesLlm => this != recraft;
  bool get polishes => this == briefPolish;
}

/// Our own design-brief wording (not copied from any upstream prompt).
const designBrief = '''
You are a vector illustrator whose work should look designed, not generated.
Before the code, write a short plan:
- Say what the picture is, its mood, and the one thing a viewer should notice first.
- Pick a canvas, a palette of three to five hex colors (one dominant, one accent, one dark, one light) and list the layers from back to front with rough positions and sizes.
Then output ONE self-contained SVG in a single ```svg block:
- Set xmlns and a viewBox matching the requested aspect (default 0 0 512 512); omit pixel width and height.
- Paint order is document order: background, large shapes, mid-ground, details, highlights.
- Wrap each layer in a <g> with a meaningful id (sky, hills, body) and give key shapes ids so later edits can target them.
- Favor primitives and short paths; use gradients from <defs> for depth, staying inside the palette; keep stroke widths and corner radii consistent.
- No scripts, external images or fonts, foreignObject or event attributes. Use <text> only when the request needs words, with a generic font stack and well inside the canvas.
- Stay compact: no editor metadata, no unused defs, coordinates rounded to one decimal.
Finally check: every part touches its body, nothing important hides behind a same-colored shape, contrast is readable, proportions are believable, and the subject still reads at 64 px.''';

const stylePresets = <String, String>{
  'flat': 'Style: flat shapes, no outlines, at most four or five colors, bold simple forms.',
  'line_icon': 'Style: line icon on a 24-unit grid, 2-unit round-capped strokes, no fills except one accent.',
  'isometric': 'Style: isometric projection with 30 degree axes and three shades per solid.',
  'geometric_logo': 'Style: built on a simple grid, two colors at most, must also work in one color.',
  'hand_drawn': 'Style: slightly irregular strokes, round caps, warm paper-toned palette.',
  'poster': 'Style: one strong focal shape, large text-free composition, depth from soft gradients.',
};

/// The instruction text sent for [prompt] under [c]; the user's request comes last.
String promptFor(Condition c, EvalPrompt prompt) {
  final request = 'Draw this as SVG: ${prompt.text}';
  return switch (c) {
    Condition.baseline || Condition.recraft => request,
    Condition.brief => '$designBrief\n\n$request',
    Condition.briefPreset || Condition.briefPolish => '$designBrief\n${stylePresets[prompt.preset] ?? ''}\n\n$request',
  };
}
