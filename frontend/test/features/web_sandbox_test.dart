import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/artifacts/ui/renderers/sandbox.dart';
import 'package:every_ai/features/artifacts/ui/renderers/svg_view.dart';
import 'package:every_ai/features/artifacts/ui/renderers/web_view.dart';
import 'package:every_ai/features/artifacts/ui/visual_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

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

  group('sandboxedDocument', () {
    '<!doctype html><meta http-equiv="Content-Security-Policy"';
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
  });

  testWidgets('a widget\'s message is sent only after the user confirms it', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(
      m.MaterialApp(
        home: EveryThemeScope(
          theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
          child: Builder(
            builder: (context) => GestureDetector(
              onTap: () => sendFromWidget(context, 'Search my chats for bank', sent.add),
              child: const Text('widget'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('widget'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Search my chats for bank'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);

    await tester.tap(find.text('widget'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(sent, ['Search my chats for bank']);
  });

  test('handler calls need the host token', () {
    expect(acceptHandlerCall(['tok', 'hi'], 'tok'), 'hi');
    expect(acceptHandlerCall(['hi'], 'tok'), isNull);
    expect(acceptHandlerCall(['other', 'hi'], 'tok'), isNull);
    expect(acceptHandlerCall(['', 'hi'], ''), isNull);
  });

  group('navigationPolicy', () {
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
  });

  group('sanitizeSvg on a parsed tree', () {
    const svgOpen =
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:x="http://www.w3.org/1999/xlink" viewBox="0 0 10 10">';

    test('drops prefixed scripts, prefixed outside hrefs and animation', () {
      final clean = sanitizeSvg(
        '$svgOpen<svg:script xmlns:svg="http://www.w3.org/2000/svg">steal()</svg:script>'
        '<image x:href="https://evil.example/p.png"/>'
        '<a href="#a"><set attributeName="href" to="javascript:steal()"/>'
        '<animate attributeName="href" values="javascript:steal()"/><text>t</text></a>'
        '<foreignObject><div>x</div></foreignObject></svg>',
      );
      expect(clean, isNot(contains('script')));
      expect(clean, isNot(contains('evil.example')));
      expect(clean, isNot(contains('<set')));
      expect(clean, isNot(contains('<animate')));
      expect(clean, isNot(contains('foreignObject')));
      expect(clean, contains('<text>t</text>'));
    });

    test('refuses CSS that hides a fetch', () {
      final clean = sanitizeSvg(
        '$svgOpen<rect style="background:u\\72l(https://evil.example/a)" width="1"/>'
        '<rect style="fill:image-set(\'https://evil.example/b\' 1x)" width="2"/>'
        '<style>.c{background:image-set("https://evil.example/c" 1x)}</style></svg>',
      );
      expect(clean, isNot(contains('evil.example')));
      expect(clean, contains('width="1"'));
      expect(clean, contains('width="2"'));
    });
  });
}
