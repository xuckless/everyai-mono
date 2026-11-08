import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/chat/ui/message_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('favicons come from the icon service, not the site', () {
    expect(faviconUrl('discoversudbury.ca'), 'https://icons.duckduckgo.com/ip3/discoversudbury.ca.ico');
  });

  testWidgets('the letter stays when the favicon cannot load', (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: EveryThemeScope(
          theme: EveryTheme.resolve(DesignLanguage.material, Brightness.dark),
          child: const Center(
            child: SiteBadge(site: 'sudbury.com', host: 'www.sudbury.com'),
          ),
        ),
      ),
    );
    // Tests have no network: the image fails and the badge keeps its letter.
    await tester.pumpAndSettle();
    expect(find.text('S'), findsOneWidget);
  });
}
