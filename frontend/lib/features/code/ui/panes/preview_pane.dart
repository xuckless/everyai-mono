import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../artifacts/ui/renderers/web_view.dart' show inlineWebSupported;
import '../../domain/code_session.dart';
import '../../domain/local_ports.dart';
import '../../panes/panes_providers.dart';
import '../../panes/processes.dart';

/// The session's web app: an address detected from Processes and the
/// terminal, or typed. Shown inline where there is a webview; elsewhere
/// (Linux) it opens in the browser.
class PreviewPane extends ConsumerStatefulWidget {
  const PreviewPane({super.key, required this.session});

  final CodeSessionInfo session;

  @override
  ConsumerState<PreviewPane> createState() => _PreviewPaneState();
}

class _PreviewPaneState extends ConsumerState<PreviewPane> {
  final _field = TextEditingController();
  InAppWebViewController? _web;

  String get _id => widget.session.id;

  @override
  void initState() {
    super.initState();
    _field.text = ref.read(previewUrlProvider(_id)) ?? '';
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _go(String typed) {
    final url = normalizePreviewUrl(typed);
    _field.text = url ?? '';
    ref.read(previewUrlProvider(_id).notifier).set(url);
    if (url != null && !inlineWebSupported) _openOutside(url);
  }

  Future<void> _openOutside(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final url = ref.watch(previewUrlProvider(_id));
    final candidates = previewCandidates(
      printed: ref.watch(sessionTerminalProvider(_id).select((t) => t.urls)),
      ports: [for (final p in ref.watch(sessionProcessesProvider(_id)).value ?? const <SessionProcess>[]) ...p.ports],
    );
    // The first server that shows up opens by itself.
    if (url == null && candidates.isNotEmpty && inlineWebSupported) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(previewUrlProvider(_id)) == null) _go(candidates.first);
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
          child: Row(
            children: [
              Expanded(
                child: AdaptiveTextField(
                  controller: _field,
                  placeholder: 'localhost:3000',
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: _go,
                ),
              ),
              if (candidates.isNotEmpty)
                AdaptiveMenuButton(
                  tooltip: 'Detected servers',
                  actions: [
                    for (final c in candidates) MenuAction(label: c, checked: c == url, onSelected: () => _go(c)),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(7),
                    child: Icon(EveryIcon.globe.of(theme.design), size: 16, color: theme.accent),
                  ),
                ),
              AdaptiveIconButton(
                icon: EveryIcon.retry,
                tooltip: 'Reload',
                size: 16,
                onPressed: url == null ? null : () => _web?.reload(),
              ),
              AdaptiveIconButton(
                icon: EveryIcon.external,
                tooltip: 'Open in browser',
                size: 16,
                onPressed: url == null ? null : () => _openOutside(url),
              ),
            ],
          ),
        ),
        Expanded(
          child: url == null
              ? _Empty(candidates: candidates, onPick: _go)
              : !inlineWebSupported
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'No built-in browser on this system; $url opens in your browser.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: theme.textMuted, fontSize: 13),
                        ),
                        const SizedBox(height: 10),
                        AdaptiveButton(label: 'Open again', onPressed: () => _openOutside(url)),
                      ],
                    ),
                  ),
                )
              : InAppWebView(
                  key: ValueKey(url),
                  initialUrlRequest: URLRequest(url: WebUri(url)),
                  initialSettings: InAppWebViewSettings(javaScriptEnabled: true, isInspectable: true),
                  onWebViewCreated: (c) => _web = c,
                  onLoadStop: (_, loaded) {
                    final now = loaded?.toString();
                    if (now != null && now != _field.text && mounted) _field.text = now;
                  },
                ),
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.candidates, required this.onPick});

  final List<String> candidates;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Start a dev server in the Terminal, or ask the agent to; '
              'its address shows up here. You can also type one above.',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.textMuted, fontSize: 13),
            ),
            for (final c in candidates) ...[
              const SizedBox(height: 8),
              AdaptiveButton(label: c, emphasis: ButtonEmphasis.secondary, onPressed: () => onPick(c)),
            ],
          ],
        ),
      ),
    );
  }
}
