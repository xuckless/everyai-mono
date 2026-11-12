import 'dart:convert';

import 'package:every_ai/core/net/sse.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<SseEvent>> decode(List<String> chunks) =>
    Stream<List<int>>.fromIterable(chunks.map(utf8.encode)).transform(const SseDecoder()).toList();

void main() {
  test('handles fields split across chunks and CRLF line endings', () async {
    final events = await decode(['da', 'ta: {"text":', '"hi"}\r\n', '\r\n', 'data: x\r\r']);
    expect(events.map((e) => e.data), ['{"text":"hi"}', 'x']);
  });

  test('multi-byte UTF-8 split across chunks', () async {
    final bytes = utf8.encode('data: héllo ✨\n\n');
    final events = await Stream<List<int>>.fromIterable([bytes.sublist(0, 9), bytes.sublist(9)])
        .transform(const SseDecoder())
        .toList();
    expect(events.single.data, 'héllo ✨');
  });
}
