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
    expect(find.text('3h'), findsOneWidget);
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
    _expectNoFocusOutline(tester.widget<TextField>(summaryEditor));

    await tester.enterText(summaryEditor, '手直ししたサマリー');
    await tester.pump();

    expect(find.text('手直ししたサマリー'), findsOneWidget);

    await tester.tapAt(const Offset(20, 180));
    await tester.pump();

    expect(find.text('サマリー'), findsOneWidget);

    await tester.tap(find.byTooltip('コピー'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('サマリーをコピーしました'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('サマリーをコピーしました'), findsNothing);
  });

  testWidgets('memo remains open when tapping outside', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SplitLogApp());

    await tester.tap(find.text('開始'));
    await tester.pump();
    await tester.tap(find.byTooltip('Splitメモ'));
    await tester.pump();

    expect(find.text('Splitメモ'), findsOneWidget);
    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      _expectNoFocusOutline(field);
    }

    await tester.tapAt(const Offset(20, 180));
    await tester.pump();

    expect(find.text('Splitメモ'), findsOneWidget);
  });

  testWidgets('confirmation uses compact controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SplitLogApp());

    await tester.tap(find.byTooltip('リセット'));
    await tester.pump();

    expect(find.text('リセットしますか？'), findsOneWidget);
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('confirmation-confirm-button')),
          )
          .height,
      26,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('confirmation-cancel-button')),
    );
    await tester.pump();

    expect(find.text('リセットしますか？'), findsNothing);
  });

  testWidgets('storage actions require confirmation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SplitLogApp());

    await tester.tap(find.byTooltip('設定'));
    await tester.pump();
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pump();

    await tester.tap(find.byTooltip('セッション情報'));
    await tester.pump();

    expect(find.text('セッション情報を削除しますか？'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('confirmation-cancel-button')),
    );
    await tester.pump();

    expect(find.text('設定'), findsOneWidget);
    expect(find.text('セッション情報を削除しますか？'), findsNothing);
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

    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('session-overflow-panel')),
        matching: find.byIcon(Icons.check),
      ),
      findsNothing,
    );

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

void _expectNoFocusOutline(TextField field) {
  final decoration = field.decoration!;
  final enabledBorder = decoration.enabledBorder as OutlineInputBorder;
  final focusedBorder = decoration.focusedBorder as OutlineInputBorder;

  expect(focusedBorder.borderSide, enabledBorder.borderSide);
}
