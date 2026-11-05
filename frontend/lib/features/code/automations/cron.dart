/// A 5-field cron expression (`minute hour day-of-month month day-of-week`), the way cron(5) reads it:
/// `*`, lists, ranges, `a-b/n` and `*/n` steps, month and weekday names, Sunday as 0 or 7. When both the
/// day-of-month and the day-of-week are restricted, a day matches if either does.
final class CronSpec {
  CronSpec._(this._minutes, this._hours, this._days, this._months, this._weekdays, this._anyDay, this._anyWeekday);

  final Set<int> _minutes, _hours, _days, _months, _weekdays;
  final bool _anyDay, _anyWeekday;

  /// The spec for [text], or throws a [FormatException] saying what is wrong.
  factory CronSpec.parse(String text) {
    final parts = text.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) {
      throw const FormatException('Use 5 fields: minute hour day-of-month month day-of-week.');
    }
    const months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
    const days = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
    final weekdays = _field(parts[4], 'day-of-week', 0, 7, days, 0);
    return CronSpec._(
      _field(parts[0], 'minute', 0, 59, const [], 0),
      _field(parts[1], 'hour', 0, 23, const [], 0),
      _field(parts[2], 'day-of-month', 1, 31, const [], 1),
      _field(parts[3], 'month', 1, 12, months, 1),
      {for (final d in weekdays) d % 7},
      parts[2].startsWith('*'),
      parts[4].startsWith('*'),
    );
  }

  static Set<int> _field(String text, String name, int min, int max, List<String> names, int nameBase) {
    int number(String s) {
      final i = names.indexOf(s.toLowerCase());
      if (i >= 0) return i + nameBase;
      final n = int.tryParse(s);
      if (n == null || n < min || n > max) throw FormatException('"$s" is not a valid $name ($min-$max).');
      return n;
    }

    final out = <int>{};
    for (final item in text.split(',')) {
      final [range, ...rest] = item.split('/');
      if (rest.length > 1 || range.isEmpty) throw FormatException('"$item" is not a valid $name.');
      final step = rest.isEmpty ? 1 : int.tryParse(rest.first);
      if (step == null || step < 1) throw FormatException('"$item" has a bad step.');
      final int from, to;
      if (range == '*') {
        (from, to) = (min, name == 'day-of-week' ? 6 : max);
      } else if (range.contains('-')) {
        final ends = range.split('-');
        if (ends.length != 2) throw FormatException('"$item" is not a valid $name.');
        (from, to) = (number(ends[0]), number(ends[1]));
        if (from > to) throw FormatException('"$item" counts backwards.');
      } else {
        from = number(range);
        // `5/10` runs from 5 to the top, like `5-max/10`.
        to = rest.isEmpty ? from : max;
      }
      for (var v = from; v <= to; v += step) {
        out.add(v);
      }
    }
    return out;
  }

  /// What is wrong with [text] as a cron expression, or null when it parses.
  static String? problem(String text) {
    try {
      CronSpec.parse(text);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  bool _dayMatches(DateTime t) {
    final dom = _days.contains(t.day);
    final dow = _weekdays.contains(t.weekday % 7);
    if (_anyDay || _anyWeekday) return dom && dow;
    return dom || dow;
  }

  /// The first minute strictly after [after] that matches, in [after]'s own zone (local or UTC); null when none
  /// falls within nine years (`0 0 31 2 *`).
  DateTime? next(DateTime after) {
    DateTime at(int y, int mo, int d, [int h = 0, int mi = 0]) =>
        after.isUtc ? DateTime.utc(y, mo, d, h, mi) : DateTime(y, mo, d, h, mi);
    var t = at(after.year, after.month, after.day, after.hour, after.minute + 1);
    final limit = after.year + 9;
    while (t.year <= limit) {
      if (!_months.contains(t.month)) {
        t = at(t.year, t.month + 1, 1);
      } else if (!_dayMatches(t)) {
        t = at(t.year, t.month, t.day + 1);
      } else if (!_hours.contains(t.hour)) {
        t = at(t.year, t.month, t.day, t.hour + 1);
      } else if (!_minutes.contains(t.minute)) {
        t = at(t.year, t.month, t.day, t.hour, t.minute + 1);
      } else if (t.isAfter(after)) {
        return t;
      } else {
        // The repeated hour when clocks go back: a wall time can resolve to its earlier occurrence.
        t = at(t.year, t.month, t.day, t.hour, t.minute + 1);
      }
    }
    return null;
  }
}
