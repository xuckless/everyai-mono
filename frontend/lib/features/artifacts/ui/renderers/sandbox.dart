import 'dart:convert';
import 'dart:ui' show Brightness, Color;

import '../../../../core/theme/every_theme.dart';

/// The script CDNs HTML artifacts may load from. Keep in step with the HTML
/// rules in `backend-exp/src/tools.zig`.
const cdnAllowlist = ['https://cdn.jsdelivr.net', 'https://cdnjs.cloudflare.com', 'https://unpkg.com'];

/// What a sandboxed page is, which decides its background and extras.
enum WebSurface {
  /// An HTML artifact: a white page unless it paints its own background.
  page,

  /// A Mermaid diagram (our own page): transparent.
  diagram,

  /// An inline chat widget: transparent, themed text, sized to its content,
  /// and `window.everyai.send(text)` posts a chat message.
  widget,
}

/// Messages a sandboxed page posts to the host page, which forwards them to
/// these webview handlers.
const sendHandler = 'everyaiSend';
const heightHandler = 'everyaiHeight';

/// The longest message a widget may send.
const maxWidgetMessage = 4000;

/// The Content-Security-Policy inside the sandbox. Interactive pages may run
/// inline scripts and load from [cdnAllowlist] only; nothing may connect
/// elsewhere, submit forms or nest frames. Static pages run no script at all.
String contentSecurityPolicy({required bool interactive}) {
  final cdns = cdnAllowlist.join(' ');
  return [
    "default-src 'none'",
    if (interactive) "script-src 'unsafe-inline' 'unsafe-eval' $cdns" else "script-src 'none'",
    "style-src 'unsafe-inline' ${interactive ? cdns : ''}".trim(),
    "img-src data: blob: ${interactive ? cdns : ''}".trim(),
    "font-src data: ${interactive ? cdns : ''}".trim(),
    'media-src data: blob:',
    if (interactive) 'connect-src $cdns' else "connect-src 'none'",
    if (interactive) 'worker-src blob:',
    "frame-src 'none'",
    "form-action 'none'",
    "base-uri 'none'",
  ].join('; ');
}

String _hex(Color c) {
  int byte(double v) => (v * 255).round().clamp(0, 255);
  return '#${[byte(c.r), byte(c.g), byte(c.b)].map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

/// The app's colors as CSS variables (`--foreground`, `--muted`, `--accent`,
/// `--background`, `--card`, `--border`, `--code`, `--radius`, `--font`), so
/// pages and widgets can match the chat around them.
String themeCss(EveryTheme t) {
  final vars = {
    'foreground': _hex(t.text),
    'muted': _hex(t.textMuted),
    'accent': _hex(t.accent),
    'primary': _hex(t.primary),
    'on-primary': _hex(t.onPrimary),
    'background': _hex(t.background),
    'card': _hex(t.surfaceRaised),
    'border': _hex(t.border),
    'code': _hex(t.codeBackground),
    'success': _hex(t.success),
    'danger': _hex(t.danger),
    'radius': '${t.radius.round()}px',
    'font': '-apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif',
  };
  final dark = t.brightness == Brightness.dark;
  return ':root{color-scheme:${dark ? 'dark' : 'light'};'
      '${vars.entries.map((e) => '--${e.key}:${e.value};').join()}}';
}

/// Base styles for widgets, at zero specificity so the widget's own CSS wins.
const _widgetCss =
    ':where(html,body){margin:0;padding:0;background:transparent}'
    ':where(body){color:var(--foreground);font:14px/1.5 var(--font)}'
    ':where(button){font:inherit;color:var(--on-primary);background:var(--primary);border:0;'
    'border-radius:var(--radius);padding:6px 12px;cursor:pointer}';

/// The bridge inside a widget: `window.everyai.send(text)` (only from a click
/// or key press, so a widget cannot post on its own) and height reports.
const _widgetBridge =
    '''(function(){
var p=window.parent;
window.everyai={send:function(t){
var a=navigator.userActivation;if(a&&!a.isActive)return false;
p.postMessage({everyai:"send",text:String(t).slice(0,$maxWidgetMessage)},"*");return true;}};
function h(){p.postMessage({everyai:"height",height:Math.ceil(document.documentElement.getBoundingClientRect().height)},"*");}
addEventListener("load",h);
if(window.ResizeObserver)new ResizeObserver(h).observe(document.documentElement);else setInterval(h,500);
})();''';

final _headTag = RegExp(r'<head\b[^>]*>', caseSensitive: false);
final _doctype = RegExp(r'^\s*<!doctype[^>]*>', caseSensitive: false);

/// [html] with [prelude] placed first in its head, so a CSP `<meta>` comes
/// before anything it governs. Without a `<head>`, the prelude goes right
/// after the doctype and the parser opens the head for it.
String injectIntoHead(String html, String prelude) {
  final head = _headTag.firstMatch(html);
  if (head != null) return html.replaceRange(head.end, head.end, prelude);
  final doctype = _doctype.firstMatch(html);
  if (doctype != null) return html.replaceRange(doctype.end, doctype.end, prelude);
  return '<!doctype html>$prelude$html';
}

/// The document that runs inside the sandbox: [html] with the CSP, the theme
/// variables and, for widgets, the base styles and the bridge.
String sandboxedDocument(String html, {required WebSurface surface, required bool interactive, String theme = ''}) {
  final csp = const HtmlEscape(HtmlEscapeMode.attribute).convert(contentSecurityPolicy(interactive: interactive));
  final prelude = StringBuffer('<meta http-equiv="Content-Security-Policy" content="$csp">')
    ..write('<style>$theme${surface == WebSurface.widget ? _widgetCss : ''}</style>');
  if (surface == WebSurface.widget && interactive) prelude.write('<script>$_widgetBridge</script>');
  return injectIntoHead(html, prelude.toString());
}

/// The sandbox attribute: scripts only when [interactive], and never
/// same-origin, top navigation, popups, forms or modals.
String sandboxAttribute({required bool interactive}) => interactive ? 'allow-scripts' : '';

/// The page the webview loads: an `<iframe sandbox>` holding
/// [sandboxedDocument] in `srcdoc`, with an opaque origin, so the content
/// cannot reach the host page, the app's storage or the webview bridge.
/// The host forwards widget messages to the app's handlers with [token]
/// first. The webview's bridge is injected into every frame, so the sandboxed
/// page could call the handlers itself; it never sees the token, and the app
/// drops calls without it (see [acceptHandlerCall]).
String sandboxedHostPage(
  String html, {
  required WebSurface surface,
  required bool interactive,
  String theme = '',
  String token = '',
}) {
  final doc = sandboxedDocument(html, surface: surface, interactive: interactive, theme: theme);
  final srcdoc = const HtmlEscape(HtmlEscapeMode.attribute).convert(doc);
  final background = surface == WebSurface.page ? '#fff' : 'transparent';
  return '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{margin:0;height:100%;background:transparent;overflow:hidden}
iframe{display:block;border:0;width:100%;height:100%;background:$background}</style></head>
<body><iframe id="f" title="content" sandbox="${sandboxAttribute(interactive: interactive)}" srcdoc="$srcdoc"></iframe>
<script>(function(){
var f=document.getElementById("f");
addEventListener("message",function(e){
if(e.source!==f.contentWindow)return;
var d=e.data,b=window.flutter_inappwebview;
if(!d||typeof d!=="object"||!b)return;
var a=navigator.userActivation;
if(d.everyai==="send"&&typeof d.text==="string"&&!(a&&!a.isActive))b.callHandler("$sendHandler",${jsonEncode(token)},d.text.slice(0,$maxWidgetMessage));
if(d.everyai==="height"&&typeof d.height==="number")b.callHandler("$heightHandler",${jsonEncode(token)},d.height);
});
})();</script></body></html>''';
}

/// A widget message as the app accepts it: trimmed, capped, non-empty.
String? acceptWidgetMessage(Object? raw) {
  if (raw is! String) return null;
  final text = raw.trim();
  if (text.isEmpty) return null;
  return text.length > maxWidgetMessage ? text.substring(0, maxWidgetMessage) : text;
}

/// The payload of a handler call that came from the host page (its first
/// argument is [token]); null for calls from anywhere else.
Object? acceptHandlerCall(List<Object?> args, String token) =>
    token.isNotEmpty && args.length == 2 && args[0] == token ? args[1] : null;
