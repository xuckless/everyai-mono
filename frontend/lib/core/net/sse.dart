import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// One dispatched Server-Sent Event.
@immutable
final class SseEvent {
  const SseEvent({this.event = 'message', required this.data, this.id});

  final String event;
  final String data;
  final String? id;

  @override
  bool operator ==(Object other) => other is SseEvent && other.event == event && other.data == data && other.id == id;

  @override
  int get hashCode => Object.hash(event, data, id);

  @override
  String toString() => 'SseEvent($event, $data${id == null ? '' : ', id: $id'})';
}

/// Decodes a `text/event-stream` byte stream into [SseEvent]s, following the
/// WHATWG event-stream rules: UTF-8, CR/LF/CRLF line endings, comment lines,
/// multi-line `data`, `event`, `id` (the last id persists), and dispatch on a blank line.
/// `retry` is accepted and ignored, since reconnection is the transport's job.
final class SseDecoder extends StreamTransformerBase<List<int>, SseEvent> {
  const SseDecoder();

  @override
  Stream<SseEvent> bind(Stream<List<int>> stream) async* {
    final data = StringBuffer();
    var hasData = false;
    var eventType = '';
    String? lastId;

    final lines = stream.transform(utf8.decoder).transform(const LineSplitter());
    var first = true;
    await for (var line in lines) {
      if (first) {
        first = false;
        if (line.startsWith('﻿')) line = line.substring(1);
      }
      if (line.isEmpty) {
        if (hasData) {
          yield SseEvent(event: eventType.isEmpty ? 'message' : eventType, data: data.toString(), id: lastId);
        }
        data.clear();
        hasData = false;
        eventType = '';
        continue;
      }
      if (line.startsWith(':')) continue;

      final colon = line.indexOf(':');
      final field = colon == -1 ? line : line.substring(0, colon);
      var value = colon == -1 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);

      switch (field) {
        case 'data':
          if (hasData) data.write('\n');
          data.write(value);
          hasData = true;
        case 'event':
          eventType = value;
        case 'id':
          if (!value.contains('\u0000')) lastId = value;
        default:
          break; // `retry` and unknown fields
      }
    }
    // Per spec, an event without its terminating blank line is discarded.
  }
}
