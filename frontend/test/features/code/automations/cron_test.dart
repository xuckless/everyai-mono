import 'package:every_ai/features/code/automations/cron.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime? next(String cron, DateTime after) => CronSpec.parse(cron).next(after);

void main() {
  group('parse', () {
    test('rejects the wrong shape', () {
      for (final bad in [
        '',
        '* * * *',
        '* * * * * *',
        '60 * * * *',
        '* 24 * * *',
        '* * 0 * *',
        '* * * 13 *',
        '* * * * 8',
      ]) {
        expect(CronSpec.problem(bad), isNotNull, reason: bad);
      }
      for (final bad in ['*/0 * * * *', '5-1 * * * *', 'a * * * *', '1-2-3 * * * *', ', * * * *', '*/2/3 * * * *']) {
        expect(CronSpec.problem(bad), isNotNull, reason: bad);
      }
    });
  });

  group('next', () {
    test('month and year rollover', () {
      expect(next('0 0 1 * *', DateTime(2026, 11, 5)), DateTime(2026, 12, 1));
      expect(next('0 0 1 * *', DateTime(2026, 12, 31, 23, 59)), DateTime(2027, 1, 1));
      expect(next('0 12 * 2 *', DateTime(2026, 3, 1)), DateTime(2027, 2, 1, 12));
    });

    test('day-of-month or day-of-week when both are restricted', () {
      // The 13th, or any Friday: Friday 2026-11-06 comes first, then Friday the 13th.
      expect(next('0 0 13 * 5', DateTime(2026, 11, 5)), DateTime(2026, 11, 6));
      expect(next('0 0 13 * 5', DateTime(2026, 11, 6)), DateTime(2026, 11, 13));
      // A star in one of them leaves the other as the only rule.
      expect(next('0 0 13 * *', DateTime(2026, 11, 5)), DateTime(2026, 11, 13));
    });
  });

  test('next is always after the instant it was asked from, also when clocks go back', () {
    final spec = CronSpec.parse('*/5 * * * *');
    final hourly = CronSpec.parse('45 1 * * *');
    // Hourly steps over a year cover every local DST change; run with TZ=America/New_York to be sure.
    for (var t = DateTime(2026, 1, 1); t.year == 2026; t = t.add(const Duration(minutes: 37))) {
      expect(spec.next(t)!.isAfter(t), isTrue, reason: '$t');
      expect(hourly.next(t)!.isAfter(t), isTrue, reason: '$t');
    }
  });
}
