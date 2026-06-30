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

  testWidgets('primary action toggles stopwatch state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SplitLogApp());

    expect(find.text('Stopped'), findsOneWidget);

    await tester.tap(find.text('再開'));
    await tester.pump();

    expect(find.text('Running'), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);

    await tester.tap(find.text('停止'));
    await tester.pump();

    expect(find.text('Stopped'), findsOneWidget);
    expect(find.text('再開'), findsOneWidget);
  });

  testWidgets('session overflow closes when tapping outside', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SplitLogApp());

    expect(find.text('2026/6/26'), findsOneWidget);

    await tester.tap(find.byTooltip('セッション一覧'));
    await tester.pump();

    expect(find.text('2026/6/26'), findsNWidgets(2));

    await tester.tapAt(const Offset(170, 150));
    await tester.pump();

    expect(find.text('2026/6/26'), findsOneWidget);
  });
}
