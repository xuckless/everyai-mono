import 'dart:convert';

/// Excalidraw (MIT), loaded from jsDelivr at pinned versions inside the web
/// sandbox; see THIRD_PARTY_NOTICES.md. React is the exact build Excalidraw's
/// jsDelivr bundle imports, so the page and the library share one React.
const excalidrawVersion = '0.18.1';
const excalidrawReactVersion = '19.2.5';
const mermaidToExcalidrawVersion = '3.1.0';

const _cdn = 'https://cdn.jsdelivr.net/npm/';

/// jsDelivr bundles each package on its own, so Excalidraw's dependencies
/// import other copies of React (and of jotai, whose store must be shared).
/// This import map sends every copy the dependency tree asks for (found by
/// walking the pinned bundles' imports) to the one the page uses.
const _sharedPackages = {
  'react': (excalidrawReactVersion, ['18.2.0', '18.3.1', '19.0.0', '19.2.7']),
  'react-dom': (excalidrawReactVersion, ['18.2.0', '18.3.1', '19.0.0']),
  'jotai': ('2.11.0', ['2.9.3']),
};

String get _importMap => jsonEncode({
  'imports': {
    for (final MapEntry(key: name, value: (target, others)) in _sharedPackages.entries)
      for (final v in others) '$_cdn$name@$v/': '$_cdn$name@$target/',
  },
});

/// The longest scene the page reports back (bigger edits are not saved).
const maxSceneLength = 8 * 1024 * 1024;

/// JSON inside a `<script type="application/json">`: no raw `<` (so neither
/// `</script` nor `<!--` can end or change the element) and no raw line or
/// paragraph separators, using JSON's own `\u` escapes.
String _scriptJson(Object? value) =>
    jsonEncode(value).replaceAll('<', r'\u003c').replaceAll('\u2028', r'\u2028').replaceAll('\u2029', r'\u2029');

/// The Excalidraw editor page for a drawing: [scene] is the artifact's
/// content (scene JSON or a bare element list, either may use skeleton
/// elements), or [mermaid] is a diagram to convert into one.
///
/// After the user changes the drawing, the page posts
/// `{everyai: "scene", scene: <full scene JSON>}` to its parent (debounced);
/// a converted diagram posts its first scene at once, as it is not saved yet.
String drawingPage({String scene = '', String? mermaid, required bool dark}) {
  final data = _scriptJson({'scene': scene, 'mermaid': mermaid, 'dark': dark, 'max': maxSceneLength});
  return '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<script type="importmap">$_importMap</script>
<link rel="stylesheet" href="$_cdn@excalidraw/excalidraw@$excalidrawVersion/dist/prod/index.css">
<style>html,body,#app{margin:0;height:100%;width:100%;overflow:hidden;background:${dark ? '#121212' : '#fff'}}
#status{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
font:14px -apple-system,system-ui,sans-serif;color:${dark ? '#aaa' : '#666'};padding:24px;text-align:center}</style>
</head><body><div id="app"></div><div id="status">Loading the drawing…</div>
<script type="application/json" id="everyai-drawing">$data</script>
<script type="module">$_drawingScript</script>
</body></html>''';
}

/// The page script. Excalidraw keeps a few settings in localStorage, which
/// throws in a sandbox without same-origin, so a memory store stands in.
const _drawingScript =
    '''
const CDN = "$_cdn";
const status = document.getElementById("status");
const fail = (m) => { status.style.display = "flex"; status.textContent = m; };
try { window.localStorage.getItem("x"); } catch (_) {
  const m = new Map();
  const s = { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => void m.set(k, String(v)),
    removeItem: (k) => void m.delete(k), clear: () => m.clear(), key: (i) => [...m.keys()][i] ?? null,
    get length() { return m.size; } };
  try { Object.defineProperty(window, "localStorage", { value: s, configurable: true }); } catch (_) {}
}
window.EXCALIDRAW_ASSET_PATH = CDN + "@excalidraw/excalidraw@$excalidrawVersion/dist/prod/";
try {
  const data = JSON.parse(document.getElementById("everyai-drawing").textContent);
  const post = (scene) => { if (scene.length <= data.max) parent.postMessage({ everyai: "scene", scene }, "*"); };
  const [React, { createRoot }, X] = await Promise.all([
    import(CDN + "react@$excalidrawReactVersion/+esm"),
    import(CDN + "react-dom@$excalidrawReactVersion/client/+esm"),
    import(CDN + "@excalidraw/excalidraw@$excalidrawVersion/+esm"),
  ]);
  let elements = [], appState = {}, files = {};
  const full = (e) => e && typeof e.seed === "number" && typeof e.version === "number";
  if (data.mermaid) {
    const { parseMermaidToExcalidraw } = await import(CDN + "@excalidraw/mermaid-to-excalidraw@$mermaidToExcalidrawVersion/+esm");
    const r = await parseMermaidToExcalidraw(data.mermaid);
    elements = X.convertToExcalidrawElements(r.elements, { regenerateIds: false });
    files = r.files || {};
  } else {
    const parsed = JSON.parse(data.scene || "[]");
    const list = Array.isArray(parsed) ? parsed : parsed.elements || [];
    elements = list.every(full) ? list : X.convertToExcalidrawElements(list, { regenerateIds: false });
    if (!Array.isArray(parsed)) { appState = parsed.appState || {}; files = parsed.files || {}; }
  }
  const shape = (els) => JSON.stringify(els.map((e) => [e.id, e.version, e.isDeleted]));
  let last = null, timer = 0;
  const settleUntil = Date.now() + 1500;
  const onChange = (els, st, fls) => {
    const now = shape(els);
    if (!data.mermaid && (last === null || Date.now() < settleUntil)) { last = now; return; }
    if (now === last) return;
    const first = last === null;
    last = now;
    clearTimeout(timer);
    timer = setTimeout(() => post(X.serializeAsJSON(els, st, fls, "local")), first ? 0 : 600);
  };
  status.style.display = "none";
  createRoot(document.getElementById("app")).render(
    React.createElement(X.Excalidraw, {
      initialData: { elements, appState: { ...appState, theme: data.dark ? "dark" : "light" }, files, scrollToContent: true },
      theme: data.dark ? "dark" : "light",
      onChange,
      UIOptions: { canvasActions: { loadScene: false, saveToActiveFile: false, export: false, saveAsImage: false } },
    }),
  );
} catch (e) {
  fail("The drawing could not be opened: " + (e && e.message ? e.message : e));
}
''';
