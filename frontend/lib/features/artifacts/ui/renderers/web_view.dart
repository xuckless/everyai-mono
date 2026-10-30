import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../chat/ui/chat_markdown.dart';

/// Whether this platform can show web content inline (Linux has no webview).
bool get inlineWebSupported =>
    kIsWeb ||
    switch (defaultTargetPlatform) {
      TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.iOS || TargetPlatform.android => true,
      _ => false,
    };

/// A page that draws Mermaid source. Mermaid loads from jsDelivr.
/// TODO: bundle mermaid.min.js as an asset to work offline.
String mermaidPage(String source, {required bool dark}) =>
    '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{margin:0;background:transparent;display:flex;justify-content:center}
.mermaid{font-family:-apple-system,system-ui,sans-serif}</style></head>
<body><pre class="mermaid">${const HtmlEscape().convert(source)}</pre>
<script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
<script>mermaid.initialize({startOnLoad:true,theme:"${dark ? 'dark' : 'default'}",securityLevel:"strict"});</script>
</body></html>''';

/// HTML in an embedded webview; elsewhere, the source with "Open in browser".
class WebContentView extends StatelessWidget {
  const WebContentView({super.key, required this.html, required this.fallbackSource, this.height = 360});

  final String html;

  /// Shown where there is no webview (Linux), e.g. the Mermaid source.
  final String fallbackSource;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (!inlineWebSupported) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChatMarkdown('```\n$fallbackSource\n```'),
          GestureDetector(
            onTap: () => openHtmlInBrowser(html),
            child: Text(
              'Open in browser',
              style: TextStyle(color: theme.accent, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      );
    }
    final view = ClipRRect(
      borderRadius: BorderRadius.circular(theme.radius),
      child: InAppWebView(
        initialData: InAppWebViewInitialData(data: html, baseUrl: WebUri('about:blank')),
        initialSettings: InAppWebViewSettings(
          transparentBackground: true,
          javaScriptEnabled: true,
          supportZoom: false,
          disableContextMenu: false,
        ),
        // Links open in the browser, never inside the artifact.
        shouldOverrideUrlLoading: (controller, action) async {
          final url = action.request.url;
          if (url != null && (url.scheme == 'http' || url.scheme == 'https') && action.isForMainFrame) {
            await launchUrl(url, mode: LaunchMode.externalApplication);
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
      ),
    );
    return height == null ? view : SizedBox(height: height, child: view);
  }
}

/// Writes [html] to a temporary file and opens it in the default browser.
Future<void> openHtmlInBrowser(String html) async {
  if (kIsWeb) return;
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/everyai-${html.hashCode.toUnsigned(32)}.html');
  await file.writeAsString(html);
  await launchUrl(Uri.file(file.path));
}
