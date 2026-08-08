import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitlog_x/core/models/session_models.dart';
import 'package:splitlog_x/core/services/session_storage_service.dart';
import 'package:splitlog_x/main.dart';

void main() {
  late _MemorySessionStorageService storage;

  setUp(() {
    storage = _MemorySessionStorageService();
  });

  testWidgets('shows SplitLog desktop preview', (WidgetTester tester) async {
    await _pumpApp(tester, storage);
    final todayTitle = _dateTitle(DateTime.now());
    final appTheme = Theme.of(tester.element(find.byType(Scaffold)));

    expect(find.text('SplitLog'), findsOneWidget);
    expect(find.text(todayTitle), findsWidgets);
    expect(find.text('全体経過'), findsOneWidget);
    expect(find.text('Split'), findsOneWidget);
    expect(find.text('4h'), findsOneWidget);
    expect(appTheme.inputDecorationTheme.focusColor, Colors.transparent);
    expect(appTheme.inputDecorationTheme.hoverColor, Colors.transparent);

    await tester.tap(find.byTooltip('サマリー'));
    await tester.pump();
    expect(find.text('テンプレ'), findsOneWidget);
  });

  testWidgets('summary time supports all three display formats', (
    WidgetTester tester,
  ) async {
    final endedAt = DateTime.utc(2026, 8, 8, 13, 6);
    final startedAt = endedAt.subtract(const Duration(hours: 1, minutes: 6));
    storage.snapshot = SplitLogStorageSnapshot(
      savedAt: endedAt,
      selectedSessionIndex: 0,
      settings: const SplitLogSettingsSnapshot(),
      sessions: [
        StopwatchSnapshot(
          session: WorkSession(
            id: 'session-summary-time',
            title: '時間表示確認',
            startedAt: startedAt,
            endedAt: endedAt,
          ),
          laps: [
            WorkLap(
              id: 'lap-summary-time',
              sessionId: 'session-summary-time',
              index: 1,
              startedAt: startedAt,
              endedAt: endedAt,
              accumulatedSeconds: 3960,
              label: '作業',
            ),
          ],
          selectedLapId: 'lap-summary-time',
          activeLapIds: const {'lap-summary-time'},
          splitAccumulationMode: SplitAccumulationMode.radio,
          state: SessionState.stopped,
          pauseStartedAt: endedAt,
          lastDistributedWholeSeconds: 3960,
          distributionCursor: 0,
          totalPausedSeconds: 0,
        ),
      ],
    );

    await _pumpApp(tester, storage);
    await tester.tap(find.byTooltip('サマリー'));
    await tester.pump();

    expect(find.text('テンプレ'), findsOneWidget);
    expect(find.text('1.1h'), findsOneWidget);
    var summaryEditor = tester.widget<TextField>(find.byType(TextField));
    expect(summaryEditor.controller!.text, contains('[ 作業 ]　(1.1h)'));

    await tester.tap(
      find.byKey(const ValueKey<String>('summary-time-format-menu')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('h（小数第2位まで）'));
    await tester.pumpAndSettle();

    expect(find.text('1.10h'), findsOneWidget);
    summaryEditor = tester.widget<TextField>(find.byType(TextField));
    expect(summaryEditor.controller!.text, contains('[ 作業 ]　(1.10h)'));
    expect(storage.snapshot!.settings.summaryTimeFormat, 'decimalHoursPrecise');

    await tester.tap(
      find.byKey(const ValueKey<String>('summary-time-format-menu')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('時間'));
    await tester.pumpAndSettle();

    expect(find.text('1時間6分'), findsOneWidget);
    summaryEditor = tester.widget<TextField>(find.byType(TextField));
    expect(summaryEditor.controller!.text, contains('[ 作業 ]　(1時間6分)'));
    expect(storage.snapshot!.settings.summaryTimeFormat, 'hourMinute');
  });

  testWidgets('settings directly selects a summary time format', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester, storage);
    await tester.tap(find.byTooltip('設定'));
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('settings-summary-time-format-menu')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('settings-summary-time-format-menu')),
    );
    await tester.pumpAndSettle();

    expect(find.text('時間'), findsOneWidget);
    expect(find.text('h（小数第1位まで）'), findsOneWidget);
    expect(find.text('h（小数第2位まで）'), findsOneWidget);

    await tester.tap(find.text('h（小数第2位まで）'));
    await tester.pumpAndSettle();

    expect(storage.snapshot!.settings.summaryTimeFormat, 'decimalHoursPrecise');
  });

  testWidgets('guide explains the current desktop features', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester, storage);

    await tester.tap(find.byTooltip('使い方'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('操作説明'));
    await tester.pumpAndSettle();

    expect(find.text('計測を始める・区切る'), findsOneWidget);
    expect(
      find.text('計測中に Split を押すと現在の区切りを確定し、次の Split を作成します。'),
      findsOneWidget,
    );

    final guideScrollView = find.byKey(
      const ValueKey<String>('guide-sections-scroll-view'),
    );
    final guideScrollable = find.descendant(
      of: guideScrollView,
      matching: find.byType(Scrollable),
    );

    await tester.scrollUntilVisible(
      find.text('サマリー表示をカスタマイズする'),
      180,
      scrollable: guideScrollable,
    );
    await tester.tap(find.text('サマリー表示をカスタマイズする'));
    await tester.pumpAndSettle();

    expect(
      find.text('カスタムでは {title}・{time}・{memo} を使い、各項目の前後や改行を自由に設定できます。'),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      find.text('データを移行・管理する'),
      180,
      scrollable: guideScrollable,
    );
    await tester.tap(find.text('データを移行・管理する'));
    await tester.pumpAndSettle();

    expect(find.text('セッションと設定はこの端末内に保存され、ほかの端末とは自動同期されません。'), findsOneWidget);
  });

  testWidgets('guide uses Windows desktop instructions on Windows', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await _pumpApp(tester, storage);

      await tester.tap(find.byTooltip('使い方'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('操作説明'));
      await tester.pumpAndSettle();

      final guideScrollView = find.byKey(
        const ValueKey<String>('guide-sections-scroll-view'),
      );
      final guideScrollable = find.descendant(
        of: guideScrollView,
        matching: find.byType(Scrollable),
      );

      await tester.scrollUntilVisible(
        find.text('ショートカットを使う'),
        180,
        scrollable: guideScrollable,
      );
      await tester.tap(find.text('ショートカットを使う'));
      await tester.pumpAndSettle();

      expect(
        find.text('Ctrl+Alt+S: Split / Ctrl+Alt+X: 停止 / Ctrl+Alt+R: 再開'),
        findsOneWidget,
      );

      await tester.scrollUntilVisible(
        find.text('データを移行・管理する'),
        180,
        scrollable: guideScrollable,
      );
      await tester.tap(find.text('データを移行・管理する'));
      await tester.pumpAndSettle();

      expect(
        find.text('旧macOS版のデータは、設定から sessions.json を選んで手動で取り込めます。'),
        findsOneWidget,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('blocks actions until storage loading completes', (
    WidgetTester tester,
  ) async {
    final delayedStorage = _DelayedMemorySessionStorageService();
    await tester.pumpWidget(SplitLogApp(storage: delayedStorage));

    await tester.tap(find.text('開始'), warnIfMissed: false);
    await tester.pump();

    expect(find.text('Running'), findsNothing);
    expect(delayedStorage.saveCount, 0);

    delayedStorage.completeLoad();
    await tester.pumpAndSettle();
    await tester.tap(find.text('開始'));
    await tester.pump();

    expect(find.text('Running'), findsOneWidget);
    expect(delayedStorage.saveCount, greaterThan(0));
  });

  testWidgets('does not overwrite storage after a loading failure', (
    WidgetTester tester,
  ) async {
    final failingStorage = _FailingLoadMemorySessionStorageService();
    await tester.pumpWidget(SplitLogApp(storage: failingStorage));
    await tester.pump();

    await tester.tap(find.text('開始'));
    await tester.pump();

    expect(find.text('Running'), findsOneWidget);
    expect(failingStorage.saveCount, 0);
  });

  testWidgets('reports a storage write failure', (WidgetTester tester) async {
    final failingStorage = _FailingSaveMemorySessionStorageService();
    await _pumpApp(tester, failingStorage);

    await tester.tap(find.text('開始'));
    await tester.pump();

    expect(find.text('データの保存に失敗しました'), findsOneWidget);
  });

  testWidgets('primary action toggles stopwatch state', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester, storage);

    expect(find.text('開始'), findsOneWidget);

    await tester.tap(find.text('開始'));
    await tester.pump();

    expect(find.text('Running'), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);

    await tester.tap(find.text('停止'));
    await tester.pump();

    expect(find.text('Stopped'), findsOneWidget);
    expect(find.text('再開'), findsOneWidget);
    expect(storage.saveCount, greaterThan(0));
  });

  testWidgets('session overflow closes when tapping outside', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester, storage);
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
    await _pumpApp(tester, storage);

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

  testWidgets('bulleted summary wraps split names in brackets', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester, storage);

    await tester.tap(find.text('開始'));
    await tester.pump();
    await tester.tap(find.byTooltip('Splitメモ'));
    await tester.pump();

    final memoFields = find.byType(TextField);
    await tester.enterText(memoFields.at(0), '実装');
    await tester.enterText(memoFields.at(1), '確認メモ');
    await tester.tap(find.widgetWithText(FilledButton, '閉じる'));
    await tester.pump();

    await tester.tap(find.byTooltip('サマリー'));
    await tester.pump();

    final summaryEditor = find.byType(TextField);
    await tester.tap(find.byKey(const ValueKey<String>('summary-format-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('テンプレート').last);
    await tester.pumpAndSettle();

    var summary = tester.widget<TextField>(summaryEditor).controller!.text;
    expect(find.text('テンプレ'), findsOneWidget);
    expect(summary, contains('[ 実装 ]'));
    expect(summary, contains('・確認メモ'));

    await tester.tap(find.byKey(const ValueKey<String>('summary-format-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('標準').last);
    await tester.pumpAndSettle();

    summary = tester.widget<TextField>(summaryEditor).controller!.text;
    expect(summary, contains('実装'));
    expect(summary, isNot(contains('[ 実装 ]')));
  });

  testWidgets('custom summary format can be created from summary menu', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester, storage);

    await tester.tap(find.text('開始'));
    await tester.pump();
    await tester.tap(find.byTooltip('サマリー'));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('summary-format-menu')));
    await tester.pumpAndSettle();
    expect(find.text('カスタムを追加'), findsOneWidget);

    await tester.tap(find.text('カスタムを追加'));
    await tester.pumpAndSettle();

    expect(find.text('カスタムフォーマット'), findsOneWidget);
    expect(find.text('削除'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey<String>('format-name-field')),
      '共有用',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('format-title-template-field')),
      '## {title}',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('カスタムフォーマット'), findsNothing);
    expect(find.text('サマリー'), findsOneWidget);
    expect(find.text('共有用'), findsOneWidget);

    final summaryEditor = find.byType(TextField);
    expect(summaryEditor, findsOneWidget);
    expect(
      tester.widget<TextField>(summaryEditor).controller!.text,
      contains('## 作業1'),
    );

    final savedSettings = storage.snapshot!.settings;
    expect(savedSettings.customSummaryFormats.single.name, '共有用');
    expect(
      savedSettings.selectedSummaryFormatId,
      savedSettings.customSummaryFormats.single.id,
    );
  });

  testWidgets('memo remains open when tapping outside', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester, storage);

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
    await _pumpApp(tester, storage);

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
    await _pumpApp(tester, storage);

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

  testWidgets('quit waits for pending data saves', (WidgetTester tester) async {
    const channel = MethodChannel('splitlog_x/app');
    final invokedMethods = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      invokedMethods.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await _pumpApp(tester, storage);
    await tester.tap(find.text('開始'));
    await tester.pump();
    await tester.tap(find.byTooltip('設定'));
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey<String>('settings-scroll-view')),
      const Offset(0, -800),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('SplitLogを終了'));
    await tester.pumpAndSettle();

    expect(storage.flushCount, greaterThan(0));
    expect(invokedMethods, contains('quitApp'));
  });

  testWidgets('custom summary format can be previewed, renamed, and deleted', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester, storage);

    await tester.tap(find.byTooltip('設定'));
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('settings-summary-format-menu')),
    );
    await tester.pumpAndSettle();

    final settingsScrollView = tester.widget<ListView>(
      find.byKey(const ValueKey<String>('settings-scroll-view')),
    );
    expect(
      settingsScrollView.padding!.resolve(TextDirection.ltr).right,
      greaterThanOrEqualTo(10),
    );
    final settingsScrollbarTheme = tester.widget<ScrollbarTheme>(
      find
          .ancestor(
            of: find.byKey(const ValueKey<String>('settings-scroll-view')),
            matching: find.byType(ScrollbarTheme),
          )
          .first,
    );
    expect(
      settingsScrollbarTheme.data.thickness!.resolve(const <WidgetState>{}),
      6,
    );
    final settingsScrollRect = tester.getRect(
      find.byKey(const ValueKey<String>('settings-scroll-view')),
    );
    final summaryFormatEditRect = tester.getRect(find.byTooltip('カスタムを追加'));
    expect(
      summaryFormatEditRect.right,
      lessThanOrEqualTo(settingsScrollRect.right - 10),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('settings-summary-format-menu')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('カスタムを追加').last);
    await tester.pumpAndSettle();

    expect(find.text('カスタムフォーマット'), findsOneWidget);
    expect(find.text('入力例'), findsOneWidget);
    expect(find.text('プレビュー'), findsOneWidget);
    expect(find.text('表示形式'), findsOneWidget);
    expect(find.text('置換ルール'), findsOneWidget);
    final formatScrollView = tester.widget<ListView>(
      find.byKey(const ValueKey<String>('summary-format-editor-scroll-view')),
    );
    expect(
      formatScrollView.padding!.resolve(TextDirection.ltr).right,
      greaterThanOrEqualTo(10),
    );
    final formatScrollbarTheme = tester.widget<ScrollbarTheme>(
      find
          .ancestor(
            of: find.byKey(
              const ValueKey<String>('summary-format-editor-scroll-view'),
            ),
            matching: find.byType(ScrollbarTheme),
          )
          .first,
    );
    expect(
      formatScrollbarTheme.data.thickness!.resolve(const <WidgetState>{}),
      6,
    );
    final addRuleButton = find.byKey(
      const ValueKey<String>('format-add-rule-button'),
    );
    expect(addRuleButton, findsOneWidget);
    final formatScrollRect = tester.getRect(
      find.byKey(const ValueKey<String>('summary-format-editor-scroll-view')),
    );
    expect(
      tester.getRect(addRuleButton).right,
      lessThanOrEqualTo(formatScrollRect.right - 10),
    );
    expect(
      tester.widget<InkWell>(addRuleButton).mouseCursor,
      SystemMouseCursors.click,
    );
    final previewColumnWidth = tester
        .getSize(
          find.byKey(const ValueKey<String>('summary-format-preview-column')),
        )
        .width;
    final editorColumnWidth = tester
        .getSize(
          find.byKey(const ValueKey<String>('summary-format-editor-column')),
        )
        .width;
    expect(previewColumnWidth, greaterThan(editorColumnWidth + 50));

    final exampleMemo = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('format-example-memo-field')),
    );
    expect(exampleMemo.minLines, 1);
    expect(exampleMemo.maxLines, 3);
    expect(exampleMemo.controller!.text, contains('\n'));
    expect(exampleMemo.controller!.text, contains(r'\n'));
    expect(exampleMemo.controller!.text, isNot(contains('↵')));

    final titleTokenButton = find.byKey(
      const ValueKey<String>('format-token-{title}'),
    );
    expect(tester.getSize(titleTokenButton).height, 16);
    expect(
      find.descendant(of: titleTokenButton, matching: find.byIcon(Icons.add)),
      findsOneWidget,
    );
    expect(
      tester.widget<InkWell>(titleTokenButton).mouseCursor,
      SystemMouseCursors.click,
    );
    expect(tester.widget<Text>(find.text('{title}')).style!.fontSize, 10);

    final titleTemplate = find.byKey(
      const ValueKey<String>('format-title-template-field'),
    );
    final initialTemplateHeight = tester.getSize(titleTemplate).height;
    await tester.enterText(titleTemplate, '#### {title}\n補足\n詳細');
    await tester.pump();
    expect(
      tester.getSize(titleTemplate).height,
      greaterThan(initialTemplateHeight),
    );

    final preview = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('summary-format-preview')),
        matching: find.byType(Text),
      ),
    );
    expect(preview.data, contains('#### API実装\n補足\n詳細'));
    expect(preview.data, isNot(contains('␣')));
    expect(preview.data, isNot(contains('□')));
    expect(preview.data, isNot(contains('↵')));

    final previewFinder = find.byKey(
      const ValueKey<String>('summary-format-preview'),
    );
    final previewSurface = tester.widget<Container>(previewFinder);
    final previewDecoration = previewSurface.decoration! as BoxDecoration;
    final previewBorder = previewDecoration.border! as Border;
    expect(previewDecoration.borderRadius, isNull);
    expect(previewBorder.left.width, 2);
    expect(previewBorder.top.style, BorderStyle.none);
    expect(previewBorder.right.style, BorderStyle.none);
    expect(previewBorder.bottom.style, BorderStyle.none);
    expect(
      find.descendant(of: previewFinder, matching: find.byType(TextField)),
      findsNothing,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('format-name-field')),
      '日報',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('settings-summary-format-menu')),
    );
    await tester.pumpAndSettle();
    expect(find.text('日報'), findsOneWidget);

    await tester.tap(find.byTooltip('カスタムを編集'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('format-name-field')),
      '日次報告',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('settings-summary-format-menu')),
    );
    await tester.pumpAndSettle();
    expect(find.text('日次報告'), findsOneWidget);

    await tester.tap(find.byTooltip('カスタムを編集'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除'));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('confirmation-confirm-button')),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('settings-summary-format-menu')),
    );
    await tester.pumpAndSettle();
    expect(find.text('テンプレ'), findsOneWidget);
  });

  testWidgets('selected session scrolls to the center of the selector', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester, storage);
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

class _MemorySessionStorageService extends SessionStorageService {
  SplitLogStorageSnapshot? snapshot;
  int saveCount = 0;
  int flushCount = 0;

  @override
  Future<SplitLogStorageSnapshot?> load() async => snapshot;

  @override
  Future<void> save(SplitLogStorageSnapshot snapshot) async {
    this.snapshot = snapshot;
    saveCount += 1;
  }

  @override
  Future<void> delete() async {
    snapshot = null;
  }

  @override
  Future<void> flush() async {
    flushCount += 1;
  }

  @override
  Future<bool> legacySnapshotExists() async => false;

  @override
  Future<SplitLogStorageSnapshot?> importLegacySnapshot() async => null;

  @override
  Future<SplitLogStorageSnapshot?> importLegacySnapshotFromContent(
    String content,
  ) async => null;
}

class _DelayedMemorySessionStorageService extends _MemorySessionStorageService {
  final Completer<SplitLogStorageSnapshot?> _loadCompleter = Completer();

  @override
  Future<SplitLogStorageSnapshot?> load() => _loadCompleter.future;

  void completeLoad([SplitLogStorageSnapshot? snapshot]) {
    _loadCompleter.complete(snapshot);
  }
}

class _FailingLoadMemorySessionStorageService
    extends _MemorySessionStorageService {
  @override
  Future<SplitLogStorageSnapshot?> load() {
    throw const SessionStorageReadException();
  }
}

class _FailingSaveMemorySessionStorageService
    extends _MemorySessionStorageService {
  @override
  Future<void> save(SplitLogStorageSnapshot snapshot) {
    throw FileSystemException('write failed');
  }
}

String _dateTitle(DateTime date) {
  return '${date.year}/${date.month}/${date.day}';
}

Future<void> _pumpApp(
  WidgetTester tester,
  SessionStorageService storage,
) async {
  await tester.pumpWidget(SplitLogApp(storage: storage));
  await tester.pumpAndSettle();
}

void _expectNoFocusOutline(TextField field) {
  final decoration = field.decoration!;
  final enabledBorder = decoration.enabledBorder as OutlineInputBorder;
  final focusedBorder = decoration.focusedBorder as OutlineInputBorder;

  expect(focusedBorder.borderSide, enabledBorder.borderSide);
}
