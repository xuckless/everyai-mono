import 'package:markdown/markdown.dart' as md;

/// Tag used for citation markers (`[1]`) in the AST.
const String kCitationTag = 'citation';

/// Attribute holding the citation's number as a decimal string.
const String kCitationIndexAttribute = 'index';

/// Citation markers as emitted by search-backed models: `[1]`, `[2]`,
/// `[1][3]`.
///
/// A bracketed integer (1-999) is a citation unless it is part of a link:
/// * followed by `(` (an inline link, `[1](url)`);
/// * followed by a non-numeric `[label]` (a full reference link) or by a
///   numeric label that is a defined link reference;
/// * itself a defined link reference (a shortcut reference link, `[1]` with
///   `[1]: url` elsewhere);
/// * followed by `:` at the start of a line (a reference definition).
///
/// Code spans and code blocks never reach this syntax. Citations nested in
/// link text are turned back into text by [unwrapCitationsInLinks].
class CitationSyntax extends md.InlineSyntax {
  CitationSyntax() : super(r'\[([1-9]\d{0,2})\]', startCharacter: 0x5B);

  static final RegExp _numericLabel = RegExp(r'\[([1-9]\d{0,2})\]');

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final start = startMatchPos ?? parser.pos;
    final source = parser.source;
    if (source.codeUnitAt(start) != 0x5B) return false;
    final match = pattern.matchAsPrefix(source, start);
    if (match == null) return false;
    final end = match.end;
    final references = parser.document.linkReferences;
    final next = end < source.length ? source[end] : '';

    if (next == '(') return false;
    if (next == '[') {
      final following = _numericLabel.matchAsPrefix(source, end);
      if (following == null) return false;
      if (references.containsKey(following[1])) return false;
    } else if (references.containsKey(match[1])) {
      return false;
    }
    if (next == ':' && _atLineStart(source, start)) return false;
    return super.tryMatch(parser, startMatchPos);
  }

  static bool _atLineStart(String source, int pos) {
    final lineStart = source.lastIndexOf('\n', pos - 1) + 1;
    return source.substring(lineStart, pos).trim().isEmpty;
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element(kCitationTag, <md.Node>[md.Text('[${match[1]}]')])..attributes[kCitationIndexAttribute] = match[1]!,
    );
    return true;
  }
}

/// Replaces citation elements inside `a` elements with their plain text, so
/// that `[see [1]](url)` stays an ordinary link.
void unwrapCitationsInLinks(List<md.Node> nodes, {bool inLink = false}) {
  for (var i = 0; i < nodes.length; i++) {
    final node = nodes[i];
    if (node is! md.Element) continue;
    if (inLink && node.tag == kCitationTag) {
      nodes[i] = md.Text(node.textContent);
      continue;
    }
    final children = node.children;
    if (children != null) unwrapCitationsInLinks(children, inLink: inLink || node.tag == 'a');
  }
}
