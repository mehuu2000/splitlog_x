import 'package:flutter/material.dart';
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

  testWidgets('summary text can be edited before copying', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SplitLogApp());

    await tester.tap(find.byTooltip('サマリー'));
    await tester.pump();

    final summaryEditor = find.byType(TextField);
    expect(summaryEditor, findsOneWidget);

    await tester.enterText(summaryEditor, '手直ししたサマリー');
    await tester.pump();

    expect(find.text('手直ししたサマリー'), findsOneWidget);
  });

  testWidgets('selected session scrolls to the center of the selector', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SplitLogApp());
    final todayTitle = _dateTitle(DateTime.now());

    for (var index = 0; index < 5; index += 1) {
      await tester.tap(find.byTooltip('セッション追加'));
      await tester.pump();
    }

    await tester.tap(find.byTooltip('セッション一覧'));
    await tester.pump();

    await tester.tap(find.text('$todayTitle-B').last);
    await tester.pumpAndSettle();

    final viewport = tester.getRect(
      find.byKey(const ValueKey<String>('session-selector-scroll-view')),
    );
    final selectedChip = tester.getRect(
      find.byKey(const ValueKey<String>('session-selector-chip-3')),
    );

    expect(selectedChip.center.dx, closeTo(viewport.center.dx, 1));
  });
}

String _dateTitle(DateTime date) {
  return '${date.year}/${date.month}/${date.day}';
}
