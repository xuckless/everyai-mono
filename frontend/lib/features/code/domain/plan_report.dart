/// An outside harness's own plan-usage report (Claude Code's `/usage`, a CLI's status text), read into parts the
/// usage card can draw. Lines it doesn't recognise stay as plain text, so a report in another shape still shows.
sealed class PlanReportPart {
  const PlanReportPart();
}

/// A sentence on its own ("You are currently using your subscription…").
final class PlanNote extends PlanReportPart {
  const PlanNote(this.text);
  final String text;
}

/// A limit: "Current week (all models): 63% used · resets Nov 10 at 8pm (America/Toronto)".
final class PlanLimit extends PlanReportPart {
  const PlanLimit({required this.label, required this.percent, this.scope, this.resets});

  /// "This week", "This session", …
  final String label;

  /// What the limit covers ("all models", "Fable"), from the parentheses.
  final String? scope;
  final int percent;

  /// "resets Nov 10 at 8pm (America/Toronto)".
  final String? resets;
}

/// A heading ("What's contributing to your usage?") and the caption under it, if any.
final class PlanHeading extends PlanReportPart {
  const PlanHeading(this.text, {this.caption});
  final String text;
  final String? caption;
}

/// A period with its counts: "Last 24h · 3731 requests · 29 sessions".
final class PlanPeriod extends PlanReportPart {
  const PlanPeriod(this.label, this.facts);
  final String label;
  final List<String> facts;
}

/// A share of usage and what it points at: "83%  Give "general-purpose" subagents a cheaper model".
final class PlanShare extends PlanReportPart {
  const PlanShare({required this.percent, required this.text, this.detail});
  final int percent;
  final String text;

  /// The part after the first " · " ("run /clear").
  final String? detail;
}

/// A named list of items with shares: "Top subagents: workflow-subagent 30%, general-purpose 13%".
final class PlanTop extends PlanReportPart {
  const PlanTop(this.label, this.items);
  final String label;
  final List<({String name, String? share})> items;
}

final _limit = RegExp(r'^(.+?):\s*(\d{1,3})%\s*used(?:\s*[·•|-]\s*(.+))?$', caseSensitive: false);
final _share = RegExp(r'^(\d{1,3})%\s+(.+)$');
final _top = RegExp(r'^(Top [^:]+):\s*(.+)$');
final _period = RegExp(r'^(Last \S+|Today|This (?:week|month)|Past \S+)\s*[·•]\s*(.+)$', caseSensitive: false);
final _sep = RegExp(r'\s+[·•]\s+');

/// Reads [text] into parts, in order. Empty when the text is blank.
List<PlanReportPart> parsePlanReport(String text) {
  final lines = text.replaceAll('\r', '').split('\n');
  final parts = <PlanReportPart>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    if (_limit.firstMatch(line) case final m?) {
      final (label, scope) = _limitLabel(m.group(1)!.trim());
      parts.add(
        PlanLimit(
          label: label,
          scope: scope,
          percent: int.parse(m.group(2)!).clamp(0, 100),
          resets: m.group(3)?.trim(),
        ),
      );
    } else if (_top.firstMatch(line) case final m?) {
      parts.add(
        PlanTop(m.group(1)!, [
          for (final item in m.group(2)!.split(RegExp(r',\s*')))
            if (item.trim().isNotEmpty) _topItem(item.trim()),
        ]),
      );
    } else if (_share.firstMatch(line) case final m?) {
      final rest = m.group(2)!.trim().split(_sep);
      parts.add(
        PlanShare(
          percent: int.parse(m.group(1)!).clamp(0, 100),
          text: rest.first,
          detail: rest.length > 1 ? rest.skip(1).join(' · ') : null,
        ),
      );
    } else if (_period.firstMatch(line) case final m?) {
      parts.add(PlanPeriod(m.group(1)!, m.group(2)!.split(_sep)));
    } else if (line.endsWith('?') || line.endsWith(':')) {
      // A heading; a short line right under it (no blank between) is its caption.
      final next = i + 1 < lines.length ? lines[i + 1].trim() : '';
      final captioned = next.isNotEmpty && _isPlain(next);
      parts.add(PlanHeading(line.replaceFirst(RegExp(r':$'), ''), caption: captioned ? next : null));
      if (captioned) i++;
    } else {
      parts.add(PlanNote(line));
    }
  }
  return parts;
}

/// Whether [line] is none of the shapes above.
bool _isPlain(String line) =>
    _limit.hasMatch(line) == false &&
    _top.hasMatch(line) == false &&
    _share.hasMatch(line) == false &&
    _period.hasMatch(line) == false;

/// "Current week (all models)" → ("This week", "all models").
(String, String?) _limitLabel(String raw) {
  final m = RegExp(r'^(.*?)\s*\(([^)]*)\)\s*$').firstMatch(raw);
  var label = (m?.group(1) ?? raw).trim();
  final scope = m?.group(2)?.trim();
  label = label.replaceFirstMapped(RegExp(r'^current\s+', caseSensitive: false), (_) => 'This ');
  if (label.isNotEmpty) label = label[0].toUpperCase() + label.substring(1);
  return (label, scope == null || scope.isEmpty ? null : scope);
}

({String name, String? share}) _topItem(String item) {
  final m = RegExp(r'^(.*?)\s+(\d{1,3}%)$').firstMatch(item);
  return m == null ? (name: item, share: null) : (name: m.group(1)!, share: m.group(2));
}
