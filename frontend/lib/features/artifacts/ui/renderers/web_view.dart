import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../chat/ui/chat_markdown.dart';
import '../../checks/web_scripts.dart';

/// Whether this platform can show web content inline (Linux has no webview).
bool get inlineWebSupported =>
    kIsWeb ||
    switch (defaultTargetPlatform) {
      TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.iOS || TargetPlatform.android => true,
      _ => false,
    };

/// A page that draws Mermaid source with the bundled Mermaid (the marker is
/// swapped for it by [withBundledScripts]), so diagrams work offline.
String mermaidPage(String source, {required bool dark}) =>
    '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{margin:0;background:transparent;display:flex;justify-content:center}
.mermaid{font-family:-apple-system,system-ui,sans-serif}</style></head>
<body><pre class="mermaid">${const HtmlEscape().convert(source)}</pre>
$mermaidScriptMarker
<script>mermaid.initialize({startOnLoad:true,theme:"${dark ? 'dark' : 'default'}",securityLevel:"strict"});</script>
</body></html>''';

/// HTML in an embedded webview; elsewhere, the source with "Open in browser".
/// Bundled scripts the page asks for ([mermaidScriptMarker]) are inlined first.
class WebContentView extends StatefulWidget {
  const WebContentView({super.key, required this.html, required this.fallbackSource, this.height = 360});

  final String html;

  /// Shown where there is no webview (Linux), e.g. the Mermaid source.
  final String fallbackSource;
  final double? height;

  @override
  State<WebContentView> createState() => _WebContentViewState();
}

class _WebContentViewState extends State<WebContentView> {
  late Future<String> _page = withBundledScripts(widget.html);

  @override
  void didUpdateWidget(WebContentView old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) _page = withBundledScripts(widget.html);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (!inlineWebSupported) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChatMarkdown('```\n${widget.fallbackSource}\n```'),
          GestureDetector(
            onTap: () => openHtmlInBrowser(widget.html),
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
      child: FutureBuilder<String>(
        future: _page,
        builder: (context, snap) {
          final page = snap.data;
          if (page == null) return const SizedBox.shrink();
          return InAppWebView(
            key: ValueKey(widget.html),
            initialData: InAppWebViewInitialData(data: page, baseUrl: WebUri('about:blank')),
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
          );
        },
      ),
    );
    return widget.height == null ? view : SizedBox(height: widget.height, child: view);
  }
}

/// Writes [html] to a temporary file and opens it in the default browser.
Future<void> openHtmlInBrowser(String html) async {
  if (kIsWeb) return;
  html = await withBundledScripts(html);
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/everyai-${html.hashCode.toUnsigned(32)}.html');
  await file.writeAsString(html);
  await launchUrl(Uri.file(file.path));
}
