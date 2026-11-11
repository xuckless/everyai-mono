// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'browser_page.dart' show pageFieldGuardJs;

// Page scripts of the OS webview backend. They run in the browser's own script world ("everyai"): they see the
// page's DOM but none of its scripts' globals or patched prototypes, and the page can't see or change them. Each is
// a function body for `callAsyncJavaScript`, reading its input from `a`.
//
// Events made by script are untrusted (`isTrusted` is false) and run no browser default of their own, so the
// defaults a page relies on are done here: focus on press, the click's activation (links, buttons, checkboxes, form
// submission), text going in, Enter, Tab, Backspace and the arrow keys. A `<select>`'s own list can't be opened by
// script: picking an option is `type` with its text.

/// The helpers every script here may use: [pageFieldGuardJs] (`sensitive`, `focused`, `deep`, ...) and a few more.
const _helpers =
    '''
$pageFieldGuardJs
const describe = (el) => {
  if (!el) return null;
  const e = el.closest('a,button,input,select,textarea,summary,label,[role],[onclick],[tabindex]') || el;
  const t = (e.getAttribute('aria-label') || e.innerText || e.value || e.alt || e.title || '').replace(/\\s+/g, ' ').trim();
  const role = e.getAttribute('role') || e.tagName.toLowerCase();
  return role + (e.id ? '#' + e.id : '') + (t ? ' "' + t.slice(0, 40) + '"' : '');
};
const textField = (el) => !!el && (el.tagName === 'TEXTAREA' ||
  (el.tagName === 'INPUT' && !/^(button|submit|reset|checkbox|radio|file|image|range|color|hidden)\$/i.test(el.type || 'text')));
const editable = (el) => !!el && (textField(el) || el.isContentEditable) && !el.disabled && !el.readOnly;
const focusable = (el) => el && el.closest &&
  el.closest('a[href],button,input,select,textarea,summary,iframe,[tabindex],[contenteditable=""],[contenteditable="true"]');
const mouse = (el, type, x, y, extra) => el.dispatchEvent(new (type.startsWith('pointer') ? PointerEvent : MouseEvent)(type, {
  bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, screenX: x, screenY: y,
  pointerId: 1, pointerType: 'mouse', isPrimary: true, ...extra }));
const fileInput = (el) => {
  if (!el) return null;
  if (el.tagName === 'INPUT' && el.type === 'file') return el;
  const label = el.closest && el.closest('label');
  const c = label && label.control;
  return c && c.tagName === 'INPUT' && c.type === 'file' ? c : null;
};
const insert = (el, text) => {
  if (document.execCommand('insertText', false, text)) return;
  if (!textField(el)) return;
  const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  const set = Object.getOwnPropertyDescriptor(proto, 'value').set;
  let s = el.value.length, e = s;
  try { s = el.selectionStart ?? s; e = el.selectionEnd ?? s; } catch (_) {}
  el.dispatchEvent(new InputEvent('beforeinput', {inputType: 'insertText', data: text, bubbles: true, cancelable: true, composed: true}));
  set.call(el, el.value.slice(0, s) + text + el.value.slice(e));
  try { el.setSelectionRange(s + text.length, s + text.length); } catch (_) {}
  el.dispatchEvent(new InputEvent('input', {inputType: 'insertText', data: text, bubbles: true, composed: true}));
  el.dispatchEvent(new Event('change', {bubbles: true}));
};
const tabbables = () => [...document.querySelectorAll(
  'a[href],button,input,select,textarea,summary,iframe,[tabindex],[contenteditable=""],[contenteditable="true"]')]
  .filter((e) => !e.disabled && e.tabIndex >= 0 && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden'
    && !(e.tagName === 'INPUT' && e.type === 'hidden'))
  .map((e, i) => [e, i]).sort((p, q) => ((p[0].tabIndex || 1e9) - (q[0].tabIndex || 1e9)) || p[1] - q[1]).map((p) => p[0]);
const scroller = (el) => {
  for (let e = el; e && e !== document.body && e !== document.documentElement; e = e.parentElement) {
    const s = getComputedStyle(e);
    if (/(auto|scroll)/.test(s.overflowY) && e.scrollHeight > e.clientHeight) return e;
  }
  return document.scrollingElement || document.documentElement;
};
''';

/// Runs the guard [check] (a function body over the helpers, returning why or null; our own text, never the
/// page's). With [focus], a focus inside another site's frame counts too: the script can't look in there.
String guardScript(String check, {required bool focus}) =>
    '''
$_helpers
const why = (() => { $check })();
if (why) return why;
const el = focused();
return $focus && el && el.tagName === 'IFRAME' ? "the focus is in a frame the browser tool can't look into" : null;''';

/// What is at `a.x`,`a.y`: a file input (`{file, multiple}`; it isn't clicked, so no picker opens) or a description.
const hitJs =
    '''
$_helpers
const el = deep(a.x, a.y);
if (!el) return {hit: null};
const f = fileInput(el);
if (f) { window.__everyaiFileTarget = f; return {file: true, multiple: f.multiple, hit: describe(el)}; }
return {hit: describe(el), select: el.tagName === 'SELECT' || !!(el.closest && el.closest('select'))};''';

/// A click of `a.count` presses at `a.x`,`a.y`: pointer and mouse events, focus on press, then the click (which runs
/// the element's own activation: links, buttons, labels, checkboxes, form submission).
const clickJs =
    '''
$_helpers
const el = deep(a.x, a.y);
if (!el) return false;
mouse(el, 'pointerover', a.x, a.y); mouse(el, 'mouseover', a.x, a.y);
mouse(el, 'pointermove', a.x, a.y); mouse(el, 'mousemove', a.x, a.y);
for (let n = 1; n <= a.count; n++) {
  const down = mouse(el, 'pointerdown', a.x, a.y, {button: 0, buttons: 1, detail: n})
    && mouse(el, 'mousedown', a.x, a.y, {button: 0, buttons: 1, detail: n});
  if (down) {
    const f = focusable(el);
    if (f && f !== document.activeElement) { try { f.focus({preventScroll: true}); } catch (_) {} }
    else if (!f && document.activeElement && document.activeElement !== document.body) document.activeElement.blur();
  }
  mouse(el, 'pointerup', a.x, a.y, {button: 0, buttons: 0, detail: n});
  mouse(el, 'mouseup', a.x, a.y, {button: 0, buttons: 0, detail: n});
  if (el.isConnected) mouse(el, 'click', a.x, a.y, {button: 0, buttons: 0, detail: n});
  if (n === 2 && el.isConnected) mouse(el, 'dblclick', a.x, a.y, {button: 0, buttons: 0, detail: 2});
}
return true;''';

/// Types `a.text` into the focused field: a select picks the option with that text or value; a text field or
/// editable element gets it at the caret (`execCommand('insertText')`, which fires the input events a keyboard
/// would, else the native value setter and the events). `a.keys`: key events around each character.
const typeJs =
    '''
$_helpers
const el = focused();
if (!el || el === document.body) return {error: 'Nothing has the focus: click the field first (by ref or selector).'};
if (el.tagName === 'IFRAME') return {error: "The focus is in another site's frame, which script from this page can't type into."};
if (el.tagName === 'SELECT') {
  const want = a.text.trim().toLowerCase();
  const o = [...el.options].find((o) => o.text.trim().toLowerCase() === want || o.value.toLowerCase() === want)
    || [...el.options].find((o) => o.text.trim().toLowerCase().includes(want));
  if (!o) return {error: 'The select has no option "' + a.text + '": its options are ' + [...el.options].map((o) => '"' + o.text.trim() + '"').join(', ') + '.'};
  el.value = o.value;
  el.dispatchEvent(new Event('input', {bubbles: true}));
  el.dispatchEvent(new Event('change', {bubbles: true}));
  return {picked: o.text.trim()};
}
if (!editable(el)) return {error: 'The focused element (' + describe(el) + ') takes no text.'};
if (a.select) { try { if (typeof el.select === 'function') el.select(); else document.execCommand('selectAll'); } catch (_) {} }
const key = (type, ch) => el.dispatchEvent(new KeyboardEvent(type, {key: ch, bubbles: true, cancelable: true, composed: true}));
if (a.keys && a.text.length <= 200) {
  for (const ch of a.text) {
    if (key('keydown', ch) && key('keypress', ch)) insert(el, ch);
    key('keyup', ch);
  }
} else {
  insert(el, a.text);
}
return {typed: true};''';

/// Presses one key on the focused element (or the page): keydown, keypress for characters, the default action
/// `a.action` (a [KeyDefault] name) unless the page prevented it, then keyup.
const pressJs =
    '''
$_helpers
const el = focused() || document.body;
const init = {key: a.key, code: a.code, keyCode: a.vk, which: a.vk, bubbles: true, cancelable: true, composed: true,
  shiftKey: a.shift, ctrlKey: a.ctrl, altKey: a.alt, metaKey: a.meta};
const go = el.dispatchEvent(new KeyboardEvent('keydown', init))
  && (!a.text || el.dispatchEvent(new KeyboardEvent('keypress', {...init, charCode: a.text.charCodeAt(0)})));
let did = null;
if (go && el.isConnected) {
  const field = editable(el);
  const page = () => scroller(el);
  switch (a.action) {
    case 'insertText': if (field) insert(el, a.text); break;
    case 'enter':
      if (el.tagName === 'TEXTAREA' || el.isContentEditable) { if (field) insert(el, '\\n'); }
      else if (el.tagName === 'INPUT' && el.form && !/^(button|reset|checkbox|radio)\$/i.test(el.type)) {
        if (el.type === 'submit' || el.type === 'image') el.click(); else el.form.requestSubmit();
        did = 'submitted the form';
      } else if (el.matches && el.matches('a[href],button,summary,[role=button],[role=link],input[type=checkbox],input[type=radio]')) {
        el.click(); did = 'pressed ' + describe(el);
      }
      break;
    case 'space':
      if (field) insert(el, ' ');
      else if (el.matches && el.matches('button,summary,[role=button],input[type=checkbox],input[type=radio],input[type=submit],input[type=button]')) { el.click(); did = 'pressed ' + describe(el); }
      else page().scrollBy({top: (a.shift ? -0.9 : 0.9) * innerHeight});
      break;
    case 'focusNext': case 'focusPrevious': {
      const all = tabbables();
      if (!all.length) break;
      const i = all.indexOf(el);
      const next = a.action === 'focusNext' ? all[(i + 1) % all.length] : all[(i - 1 + all.length) % all.length];
      next.focus();
      try { if (typeof next.select === 'function' && textField(next)) next.select(); } catch (_) {}
      did = 'the focus is on ' + describe(next);
      break;
    }
    case 'deleteBackward': if (field) document.execCommand('delete'); break;
    case 'deleteForward': if (field) document.execCommand('forwardDelete'); break;
    case 'selectAll': if (field && typeof el.select === 'function') el.select(); else document.execCommand('selectAll'); break;
    case 'undo': document.execCommand('undo'); break;
    case 'redo': document.execCommand('redo'); break;
    case 'cut': document.execCommand('cut'); break;
    case 'copy': document.execCommand('copy'); break;
    case 'arrowUp': case 'arrowDown':
      if (el.tagName === 'SELECT') {
        const n = el.selectedIndex + (a.action === 'arrowDown' ? 1 : -1);
        if (n >= 0 && n < el.options.length) { el.selectedIndex = n; el.dispatchEvent(new Event('input', {bubbles: true})); el.dispatchEvent(new Event('change', {bubbles: true})); }
      } else if (field) getSelection().modify(a.shift ? 'extend' : 'move', a.action === 'arrowDown' ? 'forward' : 'backward', 'line');
      else page().scrollBy({top: a.action === 'arrowDown' ? 40 : -40});
      break;
    case 'arrowLeft': case 'arrowRight':
      if (field) getSelection().modify(a.shift ? 'extend' : 'move', a.action === 'arrowRight' ? 'forward' : 'backward', 'character');
      else page().scrollBy({left: a.action === 'arrowRight' ? 40 : -40});
      break;
    case 'pageUp': case 'pageDown': page().scrollBy({top: (a.action === 'pageDown' ? 0.9 : -0.9) * innerHeight}); break;
    case 'home': case 'end':
      if (field) getSelection().modify(a.shift ? 'extend' : 'move', a.action === 'end' ? 'forward' : 'backward', 'lineboundary');
      else page().scrollTo({top: a.action === 'end' ? page().scrollHeight : 0});
      break;
  }
}
el.dispatchEvent(new KeyboardEvent('keyup', init));
return {prevented: !go, did};''';

/// A wheel turn of `a.dy` at `a.x`,`a.y`: the wheel event, then (unless the page took it) the scrollable element
/// under the point scrolls. Returns the page's scroll position and how far it goes.
const scrollJs =
    '''
$_helpers
const el = deep(a.x, a.y) || document.body;
const go = el.dispatchEvent(new WheelEvent('wheel', {deltaY: a.dy, deltaMode: 0, clientX: a.x, clientY: a.y,
  bubbles: true, cancelable: true, composed: true, view: window}));
if (go) scroller(el).scrollBy({top: a.dy});
await new Promise((r) => setTimeout(r, 120));
return [Math.round(scrollY), Math.max(0, document.documentElement.scrollHeight - innerHeight)];''';

/// Gives a file input the files `a.files` (`{name, type, data}` with base64 data): the input named by `a.ref`
/// (from the element list) or `a.selector`, else the one the agent's last click found.
const setFilesJs = r'''
const el = a.ref ? (window.__everyaiRefs && window.__everyaiRefs.get(a.ref))
  : a.selector ? document.querySelector(a.selector) : window.__everyaiFileTarget;
if (!el) return 'No element ' + (a.ref || a.selector || '(file input)') + ' on the page now.';
if (!(el.tagName === 'INPUT' && el.type === 'file')) return (a.ref || a.selector) + ' is not a file input.';
const dt = new DataTransfer();
for (const f of a.files) {
  const bin = atob(f.data);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  dt.items.add(new File([bytes], f.name, {type: f.type || 'application/octet-stream'}));
}
el.files = dt.files;
el.dispatchEvent(new Event('input', {bubbles: true}));
el.dispatchEvent(new Event('change', {bubbles: true}));
window.__everyaiFileTarget = null;
return null;''';

/// The centre of the first element matching `a.selector`, scrolled into view.
const centreJs = r'''
const el = document.querySelector(a.selector);
if (!el) return null;
el.scrollIntoView({block: 'center', inline: 'center'});
const r = el.getBoundingClientRect();
return {x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height};''';

/// What the focused field is: "a password field", "a one-time code field", null for an ordinary one, '' when
/// nothing that takes text has the focus.
const focusedKindJs =
    '''
$_helpers
const el = focused();
if (!el || !(el.isContentEditable || /^(input|textarea)\$/i.test(el.tagName || ''))) return '';
return sensitive(el);''';

/// Uncaught errors and failed promises go to the console the plugin reports (page world, at document start).
const errorReportJs = r'''
(() => {
  if (window.__everyaiErrors) return;
  window.__everyaiErrors = true;
  addEventListener('error', (e) => { if (e instanceof ErrorEvent) console.error('Uncaught: ' + e.message + (e.filename ? ' (' + e.filename + ':' + e.lineno + ')' : '')); });
  addEventListener('unhandledrejection', (e) => console.error('Uncaught (in promise): ' + (e.reason && (e.reason.stack || e.reason.message) || e.reason)));
})();''';
