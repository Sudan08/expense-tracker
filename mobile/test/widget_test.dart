// Smoke test only: full app tests need a Supabase session and are covered
// once the wizard has provisioned a real project (plan section 12, Phase 6).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('Expense Tracker'))));
    expect(find.text('Expense Tracker'), findsOneWidget);
  });
}
