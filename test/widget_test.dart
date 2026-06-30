import 'package:flutter_test/flutter_test.dart';
import 'package:splitlog_x/main.dart';

void main() {
  testWidgets('shows SplitLog desktop preview', (WidgetTester tester) async {
    await tester.pumpWidget(const SplitLogApp());
    final todayTitle = _dateTitle(DateTime.now());

    expect(find.text('SplitLog'), findsOneWidget);
    expect(find.text(todayTitle), findsWidgets);
    expect(find.text('全体経過'), findsOneWidget);
    expect(find.text('Split'), findsOneWidget);
  });

  testWidgets('primary action toggles stopwatch state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SplitLogApp());

    expect(find.text('開始'), findsOneWidget);

    await tester.tap(find.text('開始'));
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
    final todayTitle = _dateTitle(DateTime.now());
    final addedTitle = '$todayTitle-A';

    await tester.tap(find.byTooltip('セッション追加'));
    await tester.pump();

    final addedSessionFinder = find.text(addedTitle);
    expect(addedSessionFinder.evaluate().length, 2);

    await tester.tap(find.byTooltip('セッション一覧'));
    await tester.pump();

    expect(find.text(todayTitle), findsWidgets);
    expect(addedSessionFinder.evaluate().length, greaterThan(2));

    await tester.tapAt(const Offset(170, 150));
    await tester.pump();

    expect(addedSessionFinder.evaluate().length, 2);
  });
}

String _dateTitle(DateTime date) {
  return '${date.year}/${date.month}/${date.day}';
}
