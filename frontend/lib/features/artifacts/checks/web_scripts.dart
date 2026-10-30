import 'package:flutter/services.dart';

/// Where a page wants the bundled Mermaid library; [withBundledScripts]
/// swaps it for the script itself, so pages work offline and as a single
/// file in the browser.
const mermaidScriptMarker = '<!--everyai:mermaid.min.js-->';

/// Mermaid 11.17.2 from jsDelivr (MIT; see THIRD_PARTY_NOTICES.md).
const mermaidAsset = 'assets/web/mermaid.min.js';

/// The app's Mermaid check and PNG export (assets/web/mermaid_export.js).
const mermaidExportAsset = 'assets/web/mermaid_export.js';

final _scripts = <String, Future<String>>{};

/// A bundled script's text, loaded once.
Future<String> bundledScript(String asset, {AssetBundle? bundle}) =>
    _scripts[asset] ??= (bundle ?? rootBundle).loadString(asset, cache: false);

/// [html] with [mermaidScriptMarker] replaced by an inline copy of Mermaid.
Future<String> withBundledScripts(String html, {AssetBundle? bundle}) async {
  if (!html.contains(mermaidScriptMarker)) return html;
  return inlineScript(html, mermaidScriptMarker, await bundledScript(mermaidAsset, bundle: bundle));
}

/// Replaces [marker] in [html] with [script] in a `<script>` element. A
/// `</script` inside the script would end the element early, so it is escaped.
String inlineScript(String html, String marker, String script) =>
    html.replaceFirst(marker, '<script>${script.replaceAll('</script', r'<\/script')}</script>');
