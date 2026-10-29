import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:every_ai/main.dart';

void main() {
  testWidgets('App launches with the correct initial screen', (WidgetTester tester) async {
    // Define a placeholder widget for testing purposes.
    final placeholderScreen = Scaffold(body: Text('Placeholder Screen'));

    // Build the app with the placeholder screen as the initial screen.
    await tester.pumpWidget(MyApp(initialScreen: placeholderScreen));

    // Verify that the placeholder screen is displayed.
    expect(find.text('Placeholder Screen'), findsOneWidget);
  });

  testWidgets('Basic interaction test: Tap a button and update UI', (WidgetTester tester) async {
    // Create a test screen with a button and counter logic for testing interaction.
    int counter = 0;
    final testScreen = StatefulBuilder(
      builder: (BuildContext context, StateSetter setState) {
        return Scaffold(
          appBar: AppBar(title: Text('Test Screen')),
          body: Column(
            children: [
              Text('Counter: $counter', key: Key('counterText')),
              IconButton(
                key: Key('incrementButton'),
                icon: Icon(Icons.add),
                onPressed: () {
                  setState(() {
                    counter++;
                  });
                },
              ),
            ],
          ),
        );
      },
    );

    // Build the app with the test screen as the initial screen.
    await tester.pumpWidget(MyApp(initialScreen: testScreen));

    // Verify that the initial counter value is displayed.
    expect(find.text('Counter: 0'), findsOneWidget);

    // Tap the '+' button to increment the counter.
    await tester.tap(find.byKey(Key('incrementButton')));
    await tester.pump();

    // Verify that the counter value updates.
    expect(find.text('Counter: 0'), findsNothing);
    expect(find.text('Counter: 1'), findsOneWidget);
  });
}
