import 'package:flutter/widgets.dart';

// Syntax themes keyed by highlight.js / re_highlight scope.
//
// re_highlight emits raw scopes such as `keyword`, `title.function`,
// `title.class.inherited` or `variable.language`. The renderer resolves a
// dotted scope to its longest themed prefix (`title.function.invoke` ->
// `title.function` -> `title`), and also accepts highlight.js CSS-style keys
// with a trailing underscore (`title.function_`). A plain `title` inside a
// `class` or `function` container resolves as `title.class` /
// `title.function`.

// One Dark (Atom) palette, with the comment gray lifted for WCAG AA on the
// default dark code background.
const Color _odFg = Color(0xFFABB2BF);
const Color _odMuted = Color(0xFF8B929E);
const Color _odRed = Color(0xFFE06C75);
const Color _odOrange = Color(0xFFD19A66);
const Color _odYellow = Color(0xFFE5C07B);
const Color _odGreen = Color(0xFF98C379);
const Color _odCyan = Color(0xFF56B6C2);
const Color _odBlue = Color(0xFF61AFEF);
const Color _odPurple = Color(0xFFC678DD);

/// One Dark-like syntax theme for dark code blocks.
const Map<String, TextStyle> oneDarkSyntaxTheme = <String, TextStyle>{
  'keyword': TextStyle(color: _odPurple),
  'built_in': TextStyle(color: _odYellow),
  'type': TextStyle(color: _odYellow),
  'literal': TextStyle(color: _odCyan),
  'number': TextStyle(color: _odOrange),
  'string': TextStyle(color: _odGreen),
  'regexp': TextStyle(color: _odCyan),
  'char': TextStyle(color: _odCyan),
  'comment': TextStyle(color: _odMuted, fontStyle: FontStyle.italic),
  'doctag': TextStyle(color: _odPurple, fontStyle: FontStyle.italic),
  'title': TextStyle(color: _odBlue),
  'title.function': TextStyle(color: _odBlue),
  'title.class': TextStyle(color: _odYellow),
  'title.class.inherited': TextStyle(color: _odYellow),
  'attr': TextStyle(color: _odOrange),
  'attribute': TextStyle(color: _odOrange),
  'property': TextStyle(color: _odRed),
  'variable': TextStyle(color: _odRed),
  'variable.language': TextStyle(color: _odRed, fontStyle: FontStyle.italic),
  'variable.constant': TextStyle(color: _odOrange),
  'template-variable': TextStyle(color: _odRed),
  'params': TextStyle(color: _odOrange),
  'meta': TextStyle(color: _odBlue),
  'meta.keyword': TextStyle(color: _odPurple),
  'meta.string': TextStyle(color: _odGreen),
  'meta.prompt': TextStyle(color: _odMuted),
  'tag': TextStyle(color: _odFg),
  'name': TextStyle(color: _odRed),
  'symbol': TextStyle(color: _odCyan),
  'bullet': TextStyle(color: _odCyan),
  'link': TextStyle(color: _odBlue, decoration: TextDecoration.underline),
  'operator': TextStyle(color: _odCyan),
  'punctuation': TextStyle(color: _odFg),
  'subst': TextStyle(color: _odRed),
  'template-tag': TextStyle(color: _odPurple),
  'selector-tag': TextStyle(color: _odRed),
  'selector-id': TextStyle(color: _odBlue),
  'selector-class': TextStyle(color: _odOrange),
  'selector-attr': TextStyle(color: _odOrange),
  'selector-pseudo': TextStyle(color: _odCyan),
  'section': TextStyle(color: _odRed, fontWeight: FontWeight.bold),
  'quote': TextStyle(color: _odMuted, fontStyle: FontStyle.italic),
  'formula': TextStyle(color: _odCyan),
  'code': TextStyle(color: _odGreen),
  'emphasis': TextStyle(fontStyle: FontStyle.italic),
  'strong': TextStyle(fontWeight: FontWeight.bold),
  'addition': TextStyle(color: _odGreen, backgroundColor: Color(0x2698C379)),
  'deletion': TextStyle(color: _odRed, backgroundColor: Color(0x26E06C75)),
};

// GitHub (Primer) light palette.
const Color _ghFg = Color(0xFF1F2328);
const Color _ghMuted = Color(0xFF59636E);
const Color _ghRed = Color(0xFFCF222E);
const Color _ghPurple = Color(0xFF8250DF);
const Color _ghBlue = Color(0xFF0550AE);
const Color _ghNavy = Color(0xFF0A3069);
const Color _ghOrange = Color(0xFF953800);
const Color _ghGreen = Color(0xFF116329);
const Color _ghGold = Color(0xFF6F5100);

/// GitHub-like syntax theme for light code blocks.
const Map<String, TextStyle> githubLightSyntaxTheme = <String, TextStyle>{
  'keyword': TextStyle(color: _ghRed),
  'built_in': TextStyle(color: _ghOrange),
  'type': TextStyle(color: _ghRed),
  'literal': TextStyle(color: _ghBlue),
  'number': TextStyle(color: _ghBlue),
  'string': TextStyle(color: _ghNavy),
  'regexp': TextStyle(color: _ghNavy),
  'char': TextStyle(color: _ghBlue),
  'comment': TextStyle(color: _ghMuted, fontStyle: FontStyle.italic),
  'doctag': TextStyle(color: _ghRed, fontStyle: FontStyle.italic),
  'title': TextStyle(color: _ghPurple),
  'title.function': TextStyle(color: _ghPurple),
  'title.class': TextStyle(color: _ghOrange),
  'title.class.inherited': TextStyle(color: _ghOrange),
  'attr': TextStyle(color: _ghBlue),
  'attribute': TextStyle(color: _ghBlue),
  'property': TextStyle(color: _ghBlue),
  'variable': TextStyle(color: _ghOrange),
  'variable.language': TextStyle(color: _ghRed),
  'variable.constant': TextStyle(color: _ghBlue),
  'template-variable': TextStyle(color: _ghRed),
  'params': TextStyle(color: _ghFg),
  'meta': TextStyle(color: _ghBlue),
  'meta.keyword': TextStyle(color: _ghRed),
  'meta.string': TextStyle(color: _ghNavy),
  'meta.prompt': TextStyle(color: _ghMuted),
  'tag': TextStyle(color: _ghMuted),
  'name': TextStyle(color: _ghGreen),
  'symbol': TextStyle(color: _ghOrange),
  'bullet': TextStyle(color: _ghGold),
  'link': TextStyle(color: _ghNavy, decoration: TextDecoration.underline),
  'operator': TextStyle(color: _ghBlue),
  'punctuation': TextStyle(color: _ghFg),
  'subst': TextStyle(color: _ghFg),
  'template-tag': TextStyle(color: _ghRed),
  'selector-tag': TextStyle(color: _ghGreen),
  'selector-id': TextStyle(color: _ghBlue),
  'selector-class': TextStyle(color: _ghBlue),
  'selector-attr': TextStyle(color: _ghBlue),
  'selector-pseudo': TextStyle(color: _ghGreen),
  'section': TextStyle(color: _ghBlue, fontWeight: FontWeight.bold),
  'quote': TextStyle(color: _ghGreen),
  'formula': TextStyle(color: _ghMuted),
  'code': TextStyle(color: _ghNavy),
  'emphasis': TextStyle(fontStyle: FontStyle.italic),
  'strong': TextStyle(fontWeight: FontWeight.bold),
  'addition': TextStyle(color: _ghGreen, backgroundColor: Color(0xFFDAFBE1)),
  'deletion': TextStyle(color: Color(0xFF82071E), backgroundColor: Color(0xFFFFEBE9)),
};
