export 'svg_script_stub.dart' if (dart.library.io) 'svg_script_io.dart';

/// The chat tool that runs the model's program to make an SVG.
const svgScriptTool = 'svg_script';

/// What a program made: its SVG (the last complete `<svg>…</svg>` it printed), what else it printed, and why it
/// failed, if it did.
typedef SvgScriptRun = ({String? svg, String output, String? error});
