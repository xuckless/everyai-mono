import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'diagram_render.dart';
import 'web_scripts.dart';

/// Whether this platform can draw Mermaid in a hidden webview. Linux has no
/// webview and the web build no headless one; there diagrams stay unchecked
/// and exports keep their source.
bool get diagramChecksSupported =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.iOS || TargetPlatform.android => true,
      _ => false,
    };

DiagramRenderer? _shared;

/// The app's diagram renderer, or null where [diagramChecksSupported] is false.
DiagramRenderer? get appDiagramRenderer =>
    diagramChecksSupported ? _shared ??= CachingDiagramRenderer(_HiddenMermaidPage().render) : null;

/// A headless webview holding the bundled Mermaid and
/// assets/web/mermaid_export.js. It starts on the first render and closes
/// after a few idle minutes.
class _HiddenMermaidPage {
  static const _loadTimeout = Duration(seconds: 20);
  static const _renderTimeout = Duration(seconds: 15);
  static const _idle = Duration(minutes: 3);

  HeadlessInAppWebView? _view;
  Future<InAppWebViewController>? _ready;
  Timer? _idleTimer;

  Future<DiagramRender> render(String source) async {
    _idleTimer?.cancel();
    try {
      final controller = await (_ready ??= _start());
      final result = await controller
          .callAsyncJavaScript(
            functionBody: 'return await window.everyaiRenderMermaid(source);',
            arguments: {'source': source},
          )
          .timeout(_renderTimeout);
      if (result == null) throw const DiagramUnavailable('the webview returned nothing');
      if (result.error case final error? when error.isNotEmpty) throw DiagramUnavailable(error);
      return diagramRenderFromJs(result.value);
    } on TimeoutException {
      await _stop();
      throw const DiagramUnavailable('the webview took too long');
    } on DiagramUnavailable {
      rethrow;
    } on Object catch (e) {
      await _stop();
      throw DiagramUnavailable('$e');
    } finally {
      _idleTimer = Timer(_idle, _stop);
    }
  }

  Future<InAppWebViewController> _start() async {
    try {
      return await _load();
    } on Object {
      await _stop();
      rethrow;
    }
  }

  Future<InAppWebViewController> _load() async {
    // The export script goes in first: Mermaid's own text could hold a marker.
    final page = inlineScript(
      inlineScript(
        '<!doctype html><html><head><meta charset="utf-8"></head><body>'
            '$mermaidScriptMarker<!--everyai:export--></body></html>',
        '<!--everyai:export-->',
        await bundledScript(mermaidExportAsset),
      ),
      mermaidScriptMarker,
      await bundledScript(mermaidAsset),
    );
    final loaded = Completer<InAppWebViewController>();
    final view = HeadlessInAppWebView(
      initialSize: const Size(1600, 1200),
      initialData: InAppWebViewInitialData(data: page, baseUrl: WebUri('about:blank')),
      initialSettings: InAppWebViewSettings(javaScriptEnabled: true, transparentBackground: false),
      onLoadStop: (controller, _) {
        if (!loaded.isCompleted) loaded.complete(controller);
      },
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame != false && !loaded.isCompleted) {
          loaded.completeError(DiagramUnavailable(error.description));
        }
      },
    );
    _view = view;
    await view.run();
    final controller = await loaded.future.timeout(_loadTimeout);
    final ready = await controller.evaluateJavascript(source: 'typeof window.everyaiRenderMermaid === "function"');
    if (ready != true) throw const DiagramUnavailable('Mermaid did not load');
    return controller;
  }

  Future<void> _stop() async {
    _idleTimer?.cancel();
    final view = _view;
    _view = null;
    _ready = null;
    try {
      await view?.dispose();
    } on Object {
      // Already gone.
    }
  }
}
