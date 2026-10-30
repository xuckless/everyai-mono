import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/history/domain/date_buckets.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation conv(String id, DateTime updated, {bool pinned = false}) => Conversation(
      id: id,
      title: id,
      model: const ModelId('m'),
      createdAt: updated,
      updatedAt: updated,
      pinned: pinned,
    );

void main() {
  final now = DateTime(2026, 10, 29, 9);

  test('buckets by calendar day, pinned first, empty buckets omitted', () {
    final groups = groupByRecency([
      conv('p', DateTime(2025), pinned: true),
      conv('t', DateTime(2026, 10, 29, 1)),
      conv('y', DateTime(2026, 10, 28, 23)),
      conv('w', DateTime(2026, 10, 24)),
      conv('o', DateTime(2026, 1, 1)),
    ], now: now);
    expect(groups.map((g) => '${g.$1.name}:${g.$2.map((c) => c.id).join(',')}'), [
      'pinned:p',
      'today:t',
      'yesterday:y',
      'week:w',
      'older:o',
    ]);
  });
}
