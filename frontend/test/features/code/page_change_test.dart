// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/features/code/live/app_view.dart';
import 'package:every_ai/features/code/live/page_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PageElement el(String ref, String role, String name, {String? value, bool off = false}) =>
      PageElement(ref: ref, role: role, name: name, value: value, offscreen: off);

  test('repeated controls are folded after three', () {
    final text = pageSnapshotText(
      title: 't',
      url: 'u',
      width: 800,
      height: 600,
      scrollY: 0,
      scrollHeight: 600,
      elements: [
        for (var i = 0; i < 10; i++) ...[
          el('ref_${i * 2}', 'img', 'photo $i'),
          el('ref_${i * 2 + 1}', 'radio', '1 star'),
        ],
      ],
    );
    expect('radio "1 star"'.allMatches(text).length, 4);
    expect(text, contains('radio "1 star" ×7 more'));
    expect(text, contains('img "photo 9"'));
  });

  test('a modal dialog is named', () {
    final text = pageSnapshotText(
      title: 't',
      url: 'u',
      width: 800,
      height: 600,
      scrollY: 0,
      scrollHeight: 600,
      modal: 'Settings',
      elements: [el('ref_1', 'button', 'Close')],
    );
    expect(text, contains('A dialog is open ("Settings")'));
  });

  test('page changes: values change in place, new text shows, off-screen elements do not count', () {
    final before = [
      el('ref_1', 'searchbox', 'Search', value: ''),
      el('', 'text', '205 photos'),
      el('ref_9', 'button', 'Far', off: true),
    ];
    final after = [el('ref_1', 'searchbox', 'Search', value: '2347'), el('', 'text', '1 of 205 photos')];
    final change = pageElementsChange(before, after)!;
    expect(change, contains('Changed: ref_1 searchbox "Search" value="2347"'));
    expect(change, contains('Now shown: text "1 of 205 photos"'));
    expect(change, contains('No longer shown: text "205 photos"'));
    expect(change, isNot(contains('Far')));
    expect(pageElementsChange(after, after), isNull);
  });
}
