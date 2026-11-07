import 'svg_script.dart';

/// No Deno here (the web build): the tool is not offered.
bool get svgScriptAvailable => false;

Future<SvgScriptRun> runSvgScript(String code) async =>
    (svg: null, output: '', error: 'svg_script runs only in the desktop app.');
