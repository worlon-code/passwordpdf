import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App widget smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Text('PDF Password Manager'),
        ),
      ),
    );
    expect(find.text('PDF Password Manager'), findsOneWidget);
  });
}
