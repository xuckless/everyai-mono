/// Splits Markdown source into independently parseable top-level segments.
///
/// A segment boundary is only placed where it is provably safe: after one or
/// more blank lines, outside fenced code, display math and raw HTML blocks,
/// before a line that is not indented (so it cannot be a continuation of a
/// list item or an indented code block), and never between two list items.
///
/// Placing too few boundaries is always correct (segments are simply parsed
/// together); placing a boundary where package:markdown would not end a block
/// is what must be avoided.
library;

/// A half-open `[start, end)` range of the source.
class SourceSegment {
  const SourceSegment({
    required this.start,
    required this.end,
    required this.unterminated,
    required this.firstLineComplete,
  });

  final int start;
  final int end;

  /// Whether the segment ends inside an unclosed fence, `$$` block or raw
  /// HTML block (i.e. it is still being streamed).
  final bool unterminated;

  /// Whether the first line of the segment was terminated by a newline.
  final bool firstLineComplete;

  @override
  String toString() =>
      'SourceSegment($start, $end, '
      'unterminated: $unterminated, firstLineComplete: $firstLineComplete)';
}

final RegExp _listMarker = RegExp(r'^ {0,3}(?:[-+*]|\d{1,9}[.)])(?:[ \t]|$)');
final RegExp _fenceOpen = RegExp(r'^(`{3,}|~{3,})(.*)$');
final RegExp _htmlRawOpen = RegExp(r'^<(pre|script|style|textarea)(?:\s|>|$)', caseSensitive: false);

class _Fence {
  const _Fence(this.char, this.length);
  final String char;
  final int length;

  bool closes(String trimmedLeft) {
    final trimmed = trimmedLeft.trimRight();
    if (trimmed.length < length) return false;
    for (var i = 0; i < trimmed.length; i++) {
      if (trimmed[i] != char) return false;
    }
    return true;
  }
}

/// Whether the line starting at [offset] in [source] is a list item.
bool startsWithListItem(String source, int offset) {
  var end = source.indexOf('\n', offset);
  if (end == -1) end = source.length;
  return _listMarker.hasMatch(source.substring(offset, end));
}

/// Segments [source] starting at [offset] (which must be the start of a line).
List<SourceSegment> segmentSource(String source, [int offset = 0]) {
  final segments = <SourceSegment>[];
  var segStart = -1;
  var segIsList = false;
  var segFirstLineComplete = false;
  var sawBlank = false;

  _Fence? fence;
  String? mathCloser;
  String? htmlCloser;

  var lineStart = offset;
  while (lineStart < source.length) {
    var lineEnd = source.indexOf('\n', lineStart);
    final complete = lineEnd != -1;
    if (!complete) lineEnd = source.length;
    var content = source.substring(lineStart, lineEnd);
    if (content.endsWith('\r')) {
      content = content.substring(0, content.length - 1);
    }
    final nextLineStart = complete ? lineEnd + 1 : source.length;
    final trimmedLeft = content.trimLeft();

    if (fence != null) {
      if (fence.closes(trimmedLeft)) fence = null;
      lineStart = nextLineStart;
      continue;
    }
    if (mathCloser != null) {
      if (content.trimRight().endsWith(mathCloser)) mathCloser = null;
      lineStart = nextLineStart;
      continue;
    }
    if (htmlCloser != null) {
      if (content.toLowerCase().contains(htmlCloser)) htmlCloser = null;
      lineStart = nextLineStart;
      continue;
    }

    if (trimmedLeft.isEmpty) {
      if (segStart != -1) sawBlank = true;
      lineStart = nextLineStart;
      continue;
    }

    final indented = content.startsWith(' ') || content.startsWith('\t');
    final isListItem = _listMarker.hasMatch(content);
    if (segStart == -1) {
      segStart = lineStart;
      segIsList = isListItem;
      segFirstLineComplete = complete;
    } else if (sawBlank && !indented && !(segIsList && isListItem)) {
      segments.add(
        SourceSegment(start: segStart, end: lineStart, unterminated: false, firstLineComplete: segFirstLineComplete),
      );
      segStart = lineStart;
      segIsList = isListItem;
      segFirstLineComplete = complete;
    }
    sawBlank = false;

    // Track constructs that may contain blank lines.
    final fenceMatch = _fenceOpen.firstMatch(trimmedLeft);
    if (fenceMatch != null && !(fenceMatch[1]![0] == '`' && fenceMatch[2]!.contains('`'))) {
      fence = _Fence(fenceMatch[1]![0], fenceMatch[1]!.length);
    } else if (trimmedLeft.startsWith(r'$$') || trimmedLeft.startsWith(r'\[')) {
      final closer = trimmedLeft.startsWith(r'$$') ? r'$$' : r'\]';
      final rest = trimmedLeft.substring(2).trimRight();
      final idx = rest.indexOf(closer);
      if (idx == -1) {
        mathCloser = closer;
      }
    } else if (trimmedLeft.startsWith('<!--')) {
      if (!trimmedLeft.contains('-->', 4)) htmlCloser = '-->';
    } else {
      final html = _htmlRawOpen.firstMatch(trimmedLeft);
      if (html != null) {
        final closer = '</${html[1]!.toLowerCase()}>';
        if (!trimmedLeft.toLowerCase().contains(closer)) htmlCloser = closer;
      }
    }

    lineStart = nextLineStart;
  }

  if (segStart != -1) {
    segments.add(
      SourceSegment(
        start: segStart,
        end: source.length,
        unterminated: fence != null || mathCloser != null || htmlCloser != null,
        firstLineComplete: segFirstLineComplete,
      ),
    );
  }
  return segments;
}
