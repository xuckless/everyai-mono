import 'dart:convert';

import 'package:every_ai/core/net/sse.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<SseEvent>> decode(List<String> chunks) =>
    Stream<List<int>>.fromIterable(chunks.map(utf8.encode)).transform(const SseDecoder()).toList();

void main() {
  test('dispatches on blank lines with default event type', () async {
    expect(await decode(['data: hello\n\n']), [const SseEvent(data: 'hello')]);
  });

  test('joins multi-line data with newlines and reads event/id', () async {
    final events = await decode(['event: delta\nid: 7\ndata: a\ndata: b\n\n']);
    expect(events, [const SseEvent(event: 'delta', data: 'a\nb', id: '7')]);
  });

  test('handles fields split across chunks and CRLF line endings', () async {
    final events = await decode(['da', 'ta: {"text":', '"hi"}\r\n', '\r\n', 'data: x\r\r']);
    expect(events.map((e) => e.data), ['{"text":"hi"}', 'x']);
  });

  test('ignores comments, unknown fields and retry', () async {
    final events = await decode([': keep-alive\nretry: 100\nfoo: bar\ndata: ok\n\n']);
    expect(events, [const SseEvent(data: 'ok')]);
  });

  test('strips a single leading space only, and a BOM', () async {
    final events = await decode(['﻿data:  two spaces\n\n', 'data:none\n\n']);
    expect(events.map((e) => e.data), [' two spaces', 'none']);
  });

  test('last id persists across events; unterminated event is dropped', () async {
    final events = await decode(['id: 1\ndata: a\n\ndata: b\n\ndata: tail']);
    expect(events.map((e) => (e.data, e.id)), [('a', '1'), ('b', '1')]);
  });

  test('blank line without data dispatches nothing', () async {
    expect(await decode(['event: ping\n\n']), isEmpty);
  });

  test('multi-byte UTF-8 split across chunks', () async {
    final bytes = utf8.encode('data: héllo ✨\n\n');
    final events = await Stream<List<int>>.fromIterable([bytes.sublist(0, 9), bytes.sublist(9)])
        .transform(const SseDecoder())
        .toList();
    expect(events.single.data, 'héllo ✨');
  });
}
