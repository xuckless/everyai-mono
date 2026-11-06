// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

/// One element of a page's element list, as the model sees it: `[ref_3] button "Sign in"`.
@immutable
final class PageElement {
  const PageElement({
    required this.ref,
    required this.role,
    required this.name,
    this.value,
    this.state = const [],
    this.level,
    this.offscreen = false,
  });

  final String ref;
  final String role;
  final String name;
  final String? value;

  /// `checked`, `disabled`, `expanded`, `selected`, `focused`, `required`.
  final List<String> state;

  /// A heading's level.
  final int? level;
  final bool offscreen;

  static PageElement? fromJson(Object? j) {
    if (j is! Map) return null;
    return PageElement(
      ref: '${j['ref']}',
      role: '${j['role'] ?? ''}',
      name: '${j['name'] ?? ''}',
      value: j['value'] as String?,
      state: [for (final s in (j['state'] as List?) ?? const []) '$s'],
      level: (j['level'] as num?)?.toInt(),
      offscreen: j['off'] == true,
    );
  }

  String get line {
    if (ref.isEmpty) return 'text "${_short(name, 160)}"';
    final b = StringBuffer('[$ref] $role');
    if (level != null) b.write(' h$level');
    if (name.isNotEmpty) b.write(' "${_short(name, 80)}"');
    if (value != null && value!.isNotEmpty) b.write(' value="${_short(value!, 60)}"');
    if (state.isNotEmpty) b.write(' (${state.join(', ')})');
    return b.toString();
  }
}

String _short(String s, int n) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length <= n ? one : '${one.substring(0, n - 1)}…';
}

/// The element list's text: the page line, then one element per line ([maxElements] at most).
String pageSnapshotText({
  required String title,
  required String url,
  required int width,
  required int height,
  required int scrollY,
  required int scrollHeight,
  required List<PageElement> elements,
  int maxElements = 150,
}) {
  final shown = elements.take(maxElements).toList();
  final more = elements.length - shown.length;
  final here = [
    for (final e in shown)
      if (!e.offscreen) e,
  ];
  // Off screen: the controls only (refs scroll into view when used); their text is read after scrolling.
  final away = [
    for (final e in shown)
      if (e.offscreen && e.ref.isNotEmpty) e,
  ];
  final maxScroll = scrollHeight - height < 0 ? 0 : scrollHeight - height;
  return [
    'Page: ${_short(title, 120)} — $url (viewport $width×$height; scrolled to y=$scrollY, '
        '${maxScroll == 0
            ? 'nothing to scroll'
            : scrollY >= maxScroll
            ? 'the bottom'
            : 'can scroll to y=$maxScroll'})',
    if (shown.isEmpty)
      '(no interactive elements, headings or text found: the page may draw on a canvas; use a screenshot)',
    for (final e in here) e.line,
    if (away.isNotEmpty) 'Off screen (a ref scrolls to it):',
    for (final e in away) e.line,
    if (more > 0) '… $more more (scroll, or use a selector)',
  ].join('\n');
}

/// Page script: lists the visible interactive elements and headings (through open shadow roots and same-origin
/// frames' documents are not entered), gives each a `ref_N` kept in a page-side map (no attribute is added to the
/// DOM), and returns `{title, url, w, h, y, sh, items:[{ref, role, name, value?, state, level?, off}]}`. Refs from
/// earlier lists are dropped.
const pageSnapshotJs = r'''
(() => {
  const refs = new Map();
  window.__everyaiRefs = refs;
  // An element keeps its ref across lists; new ones get new numbers.
  const ids = window.__everyaiIds || (window.__everyaiIds = new WeakMap());
  const refOf = (el) => {
    let r = ids.get(el);
    if (!r) { r = 'ref_' + (window.__everyaiNext = (window.__everyaiNext || 0) + 1); ids.set(el, r); }
    return r;
  };
  const vw = innerWidth, vh = innerHeight;
  const out = [];
  const roleOf = (el) => {
    const r = el.getAttribute('role');
    if (r) return r;
    const tag = el.tagName.toLowerCase();
    if (tag === 'a') return el.hasAttribute('href') ? 'link' : 'text';
    if (tag === 'button' || tag === 'summary') return 'button';
    if (tag === 'select') return 'combobox';
    if (tag === 'textarea') return 'textbox';
    if (/^h[1-6]$/.test(tag)) return 'heading';
    if (tag === 'img') return 'img';
    if (tag === 'canvas') return 'canvas';
    if (tag === 'input') {
      const t = (el.type || 'text').toLowerCase();
      return ({checkbox: 'checkbox', radio: 'radio', range: 'slider', submit: 'button', button: 'button',
        reset: 'button', image: 'button', file: 'file', search: 'searchbox', number: 'spinbutton'})[t] || 'textbox';
    }
    if (el.isContentEditable) return 'textbox';
    return 'generic';
  };
  const nameOf = (el) => {
    const label = el.getAttribute('aria-label');
    if (label) return label;
    const by = el.getAttribute('aria-labelledby');
    if (by) {
      const t = by.split(/\s+/).map((id) => document.getElementById(id)?.textContent || '').join(' ').trim();
      if (t) return t;
    }
    if (el.labels && el.labels.length) return [...el.labels].map((l) => l.textContent).join(' ');
    const tag = el.tagName.toLowerCase();
    if (tag === 'input' || tag === 'textarea') return el.placeholder || el.title || el.name || '';
    if (tag === 'img') return el.alt || el.title || '';
    return (el.innerText || el.textContent || el.title || el.getAttribute('alt') || '').trim();
  };
  const interactive = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],' +
    '[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=switch],[role=option],[role=combobox],' +
    '[role=textbox],[role=slider],[contenteditable=""],[contenteditable=true],[onclick],[tabindex]:not([tabindex="-1"]),' +
    'h1,h2,h3,h4,h5,h6,img[alt]:not([alt=""]),canvas';
  const visit = (root) => {
    for (const el of root.querySelectorAll(interactive)) {
      if (out.length >= 400) return;
      const r = el.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) continue;
      const cs = getComputedStyle(el);
      if (cs.visibility === 'hidden' || cs.display === 'none' || +cs.opacity === 0) continue;
      const role = roleOf(el);
      const name = role === 'canvas' ? Math.round(r.width) + '×' + Math.round(r.height)
        : nameOf(el).replace(/\s+/g, ' ').trim().slice(0, 200);
      if (role === 'generic' && !name) continue;
      const ref = refOf(el);
      refs.set(ref, el);
      const state = [];
      if (el.disabled || el.getAttribute('aria-disabled') === 'true') state.push('disabled');
      if (el.checked || el.getAttribute('aria-checked') === 'true') state.push('checked');
      if (el.getAttribute('aria-expanded') === 'true') state.push('expanded');
      if (el.getAttribute('aria-selected') === 'true') state.push('selected');
      if (el.required) state.push('required');
      if (document.activeElement === el) state.push('focused');
      const type = (el.type || '').toLowerCase();
      const item = {ref, role, name, state, off: r.bottom < 0 || r.top > vh || r.right < 0 || r.left > vw, top: r.top};
      if ('value' in el && role !== 'button' && type !== 'password' && el.tagName !== 'BUTTON') {
        item.value = String(el.value ?? '').slice(0, 200);
      }
      if (type === 'password') item.state.push('password');
      if (role === 'heading') item.level = +(el.tagName[1] || el.getAttribute('aria-level') || 2);
      out.push(item);
    }
    for (const el of root.querySelectorAll('*')) if (el.shadowRoot) visit(el.shadowRoot);
  };
  visit(document);
  // Text the page shows outside the controls (status lines, counts, prices, errors): what an action changed.
  const listed = new Set(refs.values());
  const inListed = (el) => { for (let e = el; e; e = e.parentElement) if (listed.has(e)) return true; return false; };
  const walker = document.createTreeWalker(document.body || document, NodeFilter.SHOW_TEXT);
  const seen = new Set();
  const inSeen = (el) => { for (let e = el; e; e = e.parentElement) if (seen.has(e)) return true; return false; };
  let texts = 0;
  for (let t = walker.nextNode(); t && texts < 120; t = walker.nextNode()) {
    const el = t.parentElement;
    if (!el || inSeen(el) || /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|OPTION|LABEL)$/.test(el.tagName) || inListed(el)) continue;
    const own = [...el.childNodes].filter((c) => c.nodeType === 3).map((c) => c.textContent).join(' ')
      .replace(/\s+/g, ' ').trim();
    if (!own) continue;
    seen.add(el);
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) continue;
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none' || +cs.opacity === 0) continue;
    const full = (el.innerText || own).replace(/\s+/g, ' ').trim();
    out.push({ref: '', role: 'text', name: full.slice(0, 160), state: [], off: r.bottom < 0 || r.top > vh,
      top: r.top, left: r.left});
    texts++;
  }
  for (const i of out) if (i.left === undefined) { const el = refs.get(i.ref); i.left = el ? el.getBoundingClientRect().left : 0; }
  // Reading order: rows top to bottom (a few pixels count as one row), left to right in a row.
  out.sort((a, b) => Math.round(a.top / 8) - Math.round(b.top / 8) || a.left - b.left);
  return {title: document.title, url: location.href, w: vw, h: vh, y: Math.round(scrollY),
    sh: Math.round(document.documentElement.scrollHeight), items: out.map(({top, left, ...i}) => i)};
})()''';

/// Page script for element [ref] of the last list: scrolls it into view and returns its centre `{x, y}` in CSS
/// pixels, or null when the ref is unknown or the element left the page.
String refCentreJs(String ref) =>
    '''
(() => {
  const el = window.__everyaiRefs && window.__everyaiRefs.get(${_jsString(ref)});
  if (!el || !el.isConnected) return null;
  el.scrollIntoView({block: 'center', inline: 'center'});
  const r = el.getBoundingClientRect();
  return {x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height};
})()''';

String _jsString(String s) => "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
