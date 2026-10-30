/// The 20 eval prompts: varied buckets, a few known-hard cases, one edit turn.
class EvalPrompt {
  const EvalPrompt(this.id, this.bucket, this.text, {this.preset, this.hard = false, this.editOf});

  final int id;
  final String bucket;
  final String text;

  /// The style preset the `brief_preset` condition applies (a key of `stylePresets`).
  final String? preset;

  /// Known to be difficult (text, spatial layout, tiling, edit stability).
  final bool hard;

  /// For an edit turn, the id of the prompt whose output it revises.
  final int? editOf;
}

const evalPrompts = <EvalPrompt>[
  EvalPrompt(1, 'icons', 'A 24 px line icon of a calendar with a checkmark.', preset: 'line_icon'),
  EvalPrompt(2, 'icons', 'A set of three flat icons: cloud upload, shield, key (same style).', preset: 'flat'),
  EvalPrompt(3, 'icons', 'A rounded app icon of a paper plane, purple gradient.', preset: 'flat'),
  EvalPrompt(4, 'logos', 'A geometric logo for a coffee roaster called "Ember", one color.', preset: 'geometric_logo'),
  EvalPrompt(
    5,
    'logos',
    'A monogram logo "AK" inside a hexagon, two colors, works at 32 px.',
    preset: 'geometric_logo',
  ),
  EvalPrompt(
    6,
    'logos',
    'A minimal wordmark "Northwind" with a wind-swirl in the N.',
    preset: 'geometric_logo',
    hard: true,
  ),
  EvalPrompt(7, 'flat', 'A red fox curled up sleeping on autumn leaves.', preset: 'flat'),
  EvalPrompt(8, 'flat', 'A lighthouse at dusk with waves and a few stars.', preset: 'flat'),
  EvalPrompt(9, 'flat', 'A friendly robot waving, flat style, four colors.', preset: 'flat'),
  EvalPrompt(10, 'flat', 'A bicycle leaning against a brick wall.', preset: 'flat', hard: true),
  EvalPrompt(11, 'scenes', 'A mountain lake at sunrise with pine trees and mist layers.', preset: 'flat'),
  EvalPrompt(12, 'scenes', 'A cozy reading nook with a window, plant, lamp and cat.', preset: 'flat', hard: true),
  EvalPrompt(13, 'scenes', 'A city skyline at night with lit windows and a moon.', preset: 'flat'),
  EvalPrompt(14, 'posters', 'A retro travel poster for a fictional desert town, big sun, no text.', preset: 'poster'),
  EvalPrompt(15, 'posters', 'A seamless-feeling geometric pattern in teal and coral.', preset: 'flat', hard: true),
  EvalPrompt(16, 'posters', 'A sticker of a smiling avocado with sunglasses.', preset: 'flat'),
  EvalPrompt(17, 'diagrams', 'An isometric diagram of a three-tier web architecture.', preset: 'isometric'),
  EvalPrompt(18, 'diagrams', 'A labeled cross-section of a plant cell with 6 organelles.', preset: 'flat', hard: true),
  EvalPrompt(
    19,
    'diagrams',
    'A pie-and-legend infographic of a monthly budget (5 categories, with numbers).',
    preset: 'flat',
    hard: true,
  ),
  EvalPrompt(
    20,
    'edit',
    'Take the lighthouse and change it to daytime, make the lighthouse red and white striped, keep everything else.',
    preset: 'flat',
    hard: true,
    editOf: 8,
  ),
];
