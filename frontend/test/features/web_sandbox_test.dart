import 'dart:convert';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/artifacts/domain/artifact.dart';
import 'package:every_ai/features/artifacts/export/downloads.dart';
import 'package:every_ai/features/artifacts/ui/renderers/sandbox.dart';
import 'package:every_ai/features/artifacts/ui/renderers/svg_view.dart';
import 'package:every_ai/features/artifacts/ui/renderers/web_view.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

/// The srcdoc attribute of a host page, unescaped.
String _srcdoc(String page) {
  final m = RegExp(r'srcdoc="([^"]*)"').firstMatch(page)!;
  return m[1]!.replaceAll('&quot;', '"').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&');
}

void main() {
  group('CSP', () {
    test('interactive pages run scripts from the CDN allowlist only', () {
      final csp = contentSecurityPolicy(interactive: true);
      expect(csp, startsWith("default-src 'none'"));
      for (final cdn in cdnAllowlist) {
        expect(csp, contains(cdn));
      }
      expect(csp, contains("script-src 'unsafe-inline' 'unsafe-eval' https://cdn.jsdelivr.net"));
      expect(csp, contains("form-action 'none'"));
      expect(csp, contains("frame-src 'none'"));
      expect(csp, isNot(contains('*')));
    });

    test('static pages run no script and load nothing remote', () {
      final csp = contentSecurityPolicy(interactive: false);
      expect(csp, contains("script-src 'none'"));
      expect(csp, contains("connect-src 'none'"));
      expect(csp, isNot(contains('https://')));
    });
  });

  group('injectIntoHead', () {
    test('goes first in an existing head', () {
      expect(
        injectIntoHead('<html><head lang="x"><title>t</title></head></html>', '<P>'),
        '<html><head lang="x"><P><title>t</title></head></html>',
      );
    });
    test('goes after the doctype when there is no head', () {
      expect(injectIntoHead('<!DOCTYPE html><p>hi</p>', '<P>'), '<!DOCTYPE html><P><p>hi</p>');
    });
    test('fragments get a doctype', () {
      expect(injectIntoHead('<button>x</button>', '<P>'), '<!doctype html><P><button>x</button>');
    });
  });

  group('sandboxedHostPage', () {
    const content = '<!doctype html><html><head></head><body><script>steal()</script>"quoted"</body></html>';

    test('puts the content in an allow-scripts iframe without same-origin', () {
      final page = sandboxedHostPage(content, surface: WebSurface.page, interactive: true, token: 'tok');
      expect(page, contains('sandbox="allow-scripts"'));
      expect(page, isNot(contains('allow-same-origin')));
      expect(page, isNot(contains('allow-top-navigation')));
      expect(page, isNot(contains('allow-popups')));
      // The content is only inside the escaped srcdoc, never live in the host.
      expect(page, isNot(contains('<script>steal()')));
      final doc = _srcdoc(page);
      expect(doc, contains('<script>steal()</script>"quoted"'));
      expect(doc.indexOf('Content-Security-Policy'), lessThan(doc.indexOf('steal()')));
      expect(doc, isNot(contains('tok')), reason: 'the token stays in the host page');
      expect(page, contains('background:#fff'));
    });

    test('static pages get an empty sandbox and a no-script CSP', () {
      final page = sandboxedHostPage(content, surface: WebSurface.page, interactive: false);
      expect(page, contains('sandbox=""'));
      expect(_srcdoc(page), contains("script-src 'none'"));
    });

    test('widgets get the theme, base styles and the send bridge', () {
      final theme = EveryTheme.resolve(DesignLanguage.material, Brightness.dark);
      final page = sandboxedHostPage(
        '<button onclick="everyai.send(\'pick A\')">A</button>',
        surface: WebSurface.widget,
        interactive: true,
        theme: themeCss(theme),
        token: 'tok123',
      );
      final doc = _srcdoc(page);
      expect(doc, contains('--foreground:#'));
      expect(doc, contains('color-scheme:dark'));
      expect(doc, contains('window.everyai='));
      expect(doc, contains('userActivation'));
      expect(page, contains('background:transparent}'));
      expect(page, contains('"tok123"'));
      expect(page, contains(sendHandler));
    });

    test('pages and diagrams get no bridge', () {
      for (final s in [WebSurface.page, WebSurface.diagram]) {
        expect(
          _srcdoc(sandboxedHostPage('<p>x</p>', surface: s, interactive: true)),
          isNot(contains('window.everyai=')),
        );
      }
    });
  });

  test('handler calls need the host token', () {
    expect(acceptHandlerCall(['tok', 'hi'], 'tok'), 'hi');
    expect(acceptHandlerCall(['hi'], 'tok'), isNull);
    expect(acceptHandlerCall(['other', 'hi'], 'tok'), isNull);
    expect(acceptHandlerCall(['', 'hi'], ''), isNull);
  });

  test('widget messages are trimmed, capped and non-empty', () {
    expect(acceptWidgetMessage('  pick A '), 'pick A');
    expect(acceptWidgetMessage('   '), isNull);
    expect(acceptWidgetMessage(42), isNull);
    expect(acceptWidgetMessage('x' * 5000)!.length, maxWidgetMessage);
  });

  group('navigationPolicy', () {
    test('a clicked link opens in the browser and the frame stays', () async {
      final opened = <Uri>[];
      final policy = await navigationPolicy(
        Uri.parse('https://example.org/a'),
        userClicked: true,
        open: (u) async {
          opened.add(u);
          return null;
        },
      );
      expect(policy, NavigationActionPolicy.CANCEL);
      expect(opened, [Uri.parse('https://example.org/a')]);
    });

    test('script redirects and other schemes are cancelled silently', () async {
      final opened = <Uri>[];
      Future<Object?> open(Uri u) async {
        opened.add(u);
        return null;
      }

      expect(
        await navigationPolicy(Uri.parse('https://evil.example/x'), userClicked: false, open: open),
        NavigationActionPolicy.CANCEL,
      );
      expect(
        await navigationPolicy(Uri.parse('file:///etc/passwd'), userClicked: true, open: open),
        NavigationActionPolicy.CANCEL,
      );
      expect(opened, isEmpty);
    });

    test('srcdoc and blank frames load', () async {
      Future<Object?> open(Uri u) async => null;
      expect(
        await navigationPolicy(Uri.parse('about:srcdoc'), userClicked: false, open: open),
        NavigationActionPolicy.ALLOW,
      );
      expect(
        await navigationPolicy(Uri.parse('about:blank'), userClicked: false, open: open),
        NavigationActionPolicy.ALLOW,
      );
    });
  });

  test('render_widget is an inline widget visual', () {
    final v = Visual.fromPart(
      ToolCallPart(
        toolName: 'render_widget',
        argumentsJson: jsonEncode({'title': 'Tip calculator', 'html': '<input type=range>'}),
        callId: 'w1',
      ),
    )!;
    expect(v.kind, VisualKind.widget);
    expect(v.kind.opensInPanel, isFalse);
    expect(v.title, 'Tip calculator');
    expect(exportOf(v).extension, 'html');
    expect(exportOf(v).text, '<input type=range>');
  });

  test('sanitizeSvg keeps fragment links and drops outside references', () {
    final clean = sanitizeSvg(
      '<svg viewBox="0 0 10 10"><defs><linearGradient id="g"/></defs>'
      '<style>@import url(https://evil.example/a.css); .a{fill:url(#g)} .b{background:url("https://evil.example/t")}</style>'
      '<use href="#shape"/><use xlink:href="data:image/svg+xml;base64,AAA"/>'
      '<image href="data:image/png;base64,AAAA"/><a href="javascript:x()"><rect onmouseover=x() width="1"/></a>'
      '<script src="https://evil.example/s.js"/></svg>',
    );
    expect(clean, contains('href="#shape"'));
    expect(clean, contains('url(#g)'));
    expect(clean, contains('data:image/png'));
    expect(clean, isNot(contains('evil.example')));
    expect(clean, isNot(contains('javascript:')));
    expect(clean, isNot(contains('svg+xml')));
    expect(clean, isNot(contains('onmouseover')));
    expect(clean, isNot(contains('<script')));
  });
}
