import '../../chat/domain/message.dart';

enum RecencyBucket {
  pinned('Pinned'),
  today('Today'),
  yesterday('Yesterday'),
  week('Previous 7 days'),
  month('Previous 30 days'),
  older('Older');

  const RecencyBucket(this.label);
  final String label;

  static RecencyBucket of(Conversation c, DateTime now) {
    if (c.pinned) return pinned;
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(c.updatedAt.year, c.updatedAt.month, c.updatedAt.day);
    final days = today.difference(day).inDays;
    return switch (days) {
      <= 0 => RecencyBucket.today,
      1 => yesterday,
      <= 7 => week,
      <= 30 => month,
      _ => older,
    };
  }
}

/// Groups conversations (already sorted pinned-first, newest-first) into
/// non-empty buckets in display order. Single pass, keeps input order.
List<(RecencyBucket, List<Conversation>)> groupByRecency(List<Conversation> items, {required DateTime now}) {
  final buckets = <RecencyBucket, List<Conversation>>{};
  for (final c in items) {
    (buckets[RecencyBucket.of(c, now)] ??= []).add(c);
  }
  return [
    for (final b in RecencyBucket.values)
      if (buckets[b] case final list?) (b, list),
  ];
}
