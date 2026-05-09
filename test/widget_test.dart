import 'package:flutter_test/flutter_test.dart';
import 'package:narrator/app.dart';

void main() {
  testWidgets('NarratorApp renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const NarratorApp());
    expect(find.byType(NarratorApp), findsOneWidget);
  });
}
