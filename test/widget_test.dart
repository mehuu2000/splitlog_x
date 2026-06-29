import 'package:flutter_test/flutter_test.dart';
import 'package:splitlog_x/main.dart';

void main() {
  testWidgets('shows SplitLog desktop preview', (WidgetTester tester) async {
    await tester.pumpWidget(const SplitLogApp());

    expect(find.text('SplitLog'), findsOneWidget);
    expect(find.text('2026/6/28'), findsWidgets);
    expect(find.text('全体経過'), findsOneWidget);
    expect(find.text('Split'), findsOneWidget);
  });
}
