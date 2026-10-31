import 'package:every_ai/app/shell.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/core/ui/adaptive_page.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_ui/cupertino_ui.dart' as c;
import 'package:material_ui/material_ui.dart' as m;

void main() {
  testWidgets('a page header sits below the translucent bar and stays there', (tester) async {
    await tester.pumpWidget(
      m.MaterialApp(
        builder: (context, child) =>
            EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.cupertino, Brightness.dark), child: child!),
        home: ShellScope(
          sidebarVisible: true,
          compact: false,
          toggleSidebar: () {},
          child: AdaptivePage(
            title: 'Artifacts',
            header: const SizedBox(height: 40, child: Text('search')),
            body: ListView(children: [for (var i = 0; i < 60; i++) SizedBox(height: 40, child: Text('row $i'))]),
          ),
        ),
      ),
    );
    final barBottom = tester.getBottomLeft(find.byType(c.CupertinoNavigationBar)).dy;
    expect(tester.getTopLeft(find.text('search')).dy, greaterThanOrEqualTo(barBottom));
    expect(tester.getTopLeft(find.text('row 0')).dy, greaterThanOrEqualTo(barBottom + 40));

    await tester.drag(find.text('row 3'), const Offset(0, -300));
    await tester.pump();
    expect(tester.getTopLeft(find.text('search')).dy, greaterThanOrEqualTo(barBottom));
  });
}
