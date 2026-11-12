import 'package:every_ai/core/config/billing_flag.dart';
import 'package:every_ai/features/usage/usage_stats.dart';
import 'package:flutter_test/flutter_test.dart';

int _s(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

void main() {
  // Written for metered credits; the parked default has billing_parked_test.dart.
  setUp(() => BillingFlag.enabled = true);
  tearDown(() => BillingFlag.enabled = false);

  final now = DateTime(2026, 10, 30, 15); // a Friday

  test('aggregate parses and series fills empty days and folds extra keys into Other', () {
    final today = DateTime(2026, 10, 30);
    final yesterday = DateTime(2026, 10, 29);
    Map<String, Object?> b(DateTime? at, String key, int micros, {int cached = 0}) => {
      'start': at == null ? 0 : _s(at),
      'key': key,
      'calls': 1,
      'prompt_tokens': 1000,
      'completion_tokens': 100,
      'cached_tokens': cached,
      'charged_micros': micros,
      'saved_micros': cached,
    };
    final agg = UsageAggregate.fromJson({
      'buckets': [
        b(yesterday, 'a', 3000000),
        b(today, 'a', 1000000),
        b(today, 'b', 500000),
        b(today, 'c', 200000),
        b(DateTime(2026, 1, 1), 'a', 9), // outside the range: dropped
      ],
      'keys': [b(null, 'a', 4000000), b(null, 'b', 500000), b(null, 'c', 200000)],
      'total': b(null, '', 4700000, cached: 500),
    });
    expect(agg.total.chargedMicros, 4700000);
    expect(agg.total.cacheShare, 0.5);
    expect(agg.keys.first.start, isNull);

    final s = UsageSeries.from(agg, range: UsageRange.week, now: now, top: 2);
    expect(s.starts, hasLength(7));
    expect(s.keys, ['a', 'b', UsageSeries.other]);
    expect(s.values[5], [3.0, 0, 0]);
    expect(s.values[6], [1.0, 0.5, 0.2]);
    expect(s.values[0], [0, 0, 0]);
    expect(s.maxStack, closeTo(3.0, 1e-9));

    final tokens = UsageSeries.from(agg, range: UsageRange.week, now: now, metric: UsageMetric.tokens);
    expect(tokens.keys, hasLength(3));
    expect(tokens.values[6], [1100, 1100, 1100]);
  });
}
