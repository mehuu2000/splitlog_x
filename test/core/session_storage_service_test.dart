import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitlog_x/core/models/session_models.dart';
import 'package:splitlog_x/core/services/session_storage_service.dart';

void main() {
  late Directory tempDirectory;
  late File storageFile;
  late File legacyFile;

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync(
      'splitlog_storage_test_',
    );
    storageFile = File('${tempDirectory.path}/sessions.json');
    legacyFile = File('${tempDirectory.path}/legacy_sessions.json');
  });

  tearDown(() {
    if (tempDirectory.existsSync()) {
      tempDirectory.deleteSync(recursive: true);
    }
  });

  test('saves and loads Flutter storage snapshot', () async {
    final service = SessionStorageService(
      storageFile: storageFile,
      legacyStorageFile: legacyFile,
    );
    final startedAt = DateTime.utc(2026, 6, 30, 12);
    final snapshot = SplitLogStorageSnapshot(
      savedAt: startedAt,
      selectedSessionIndex: 0,
      settings: const SplitLogSettingsSnapshot(
        isLocked: true,
        isMonochrome: true,
        ringHoursPerCycle: 8,
        defaultSplitMode: SplitAccumulationMode.checkbox,
        summaryMemoFormat: 'plain',
        summaryTimeFormat: 'hourMinute',
        shortcutsEnabled: false,
      ),
      sessions: [
        StopwatchSnapshot(
          session: WorkSession(
            id: 'session-1',
            title: '2026/6/30',
            startedAt: startedAt,
          ),
          laps: [
            WorkLap(
              id: 'lap-1',
              sessionId: 'session-1',
              index: 1,
              startedAt: startedAt,
              accumulatedSeconds: 12,
              label: '実装',
              memo: 'memo',
            ),
          ],
          selectedLapId: 'lap-1',
          activeLapIds: {'lap-1'},
          splitAccumulationMode: SplitAccumulationMode.checkbox,
          state: SessionState.stopped,
          pauseStartedAt: startedAt.add(const Duration(seconds: 12)),
          lastDistributedWholeSeconds: 12,
          distributionCursor: 0,
          totalPausedSeconds: 0,
        ),
      ],
    );

    await service.save(snapshot);
    final restored = await service.load();

    expect(restored, isNotNull);
    expect(restored!.settings.isLocked, isTrue);
    expect(restored.settings.ringHoursPerCycle, 8);
    expect(restored.settings.shortcutsEnabled, isFalse);
    expect(restored.sessions.single.session?.title, '2026/6/30');
    expect(restored.sessions.single.laps.single.memo, 'memo');
  });

  test('imports legacy SplitLog sessions.json format', () async {
    final service = SessionStorageService(
      storageFile: storageFile,
      legacyStorageFile: legacyFile,
    );
    await legacyFile.writeAsString('''
{
  "schemaVersion": 4,
  "savedAt": 804427200,
  "contexts": [
    {
      "session": {
        "id": "session-legacy",
        "title": "旧セッション",
        "startedAt": 804427200
      },
      "laps": [
        {
          "id": "lap-legacy",
          "sessionId": "session-legacy",
          "index": 1,
          "startedAt": 804427200,
          "accumulatedDuration": 42.9,
          "label": "旧Split",
          "memo": "旧メモ"
        }
      ],
      "selectedLapID": "lap-legacy",
      "activeLapIDs": ["lap-legacy"],
      "splitAccumulationMode": "checkbox",
      "state": "stopped",
      "lastDistributedWholeSeconds": 42,
      "distributionCursor": 0,
      "totalPausedDuration": 0
    }
  ],
  "sessionOrder": ["session-legacy"],
  "selectedSessionID": "session-legacy",
  "nextSessionNumber": 2
}
''');

    expect(await service.legacySnapshotExists(), isTrue);
    final imported = await service.importLegacySnapshot();

    expect(imported, isNotNull);
    expect(imported!.sessions.single.session?.title, '旧セッション');
    expect(imported.sessions.single.laps.single.label, '旧Split');
    expect(imported.sessions.single.laps.single.accumulatedSeconds, 42);
    expect(
      imported.sessions.single.splitAccumulationMode,
      SplitAccumulationMode.checkbox,
    );
  });

  test('imports legacy sessions from manually selected file content', () async {
    final service = SessionStorageService(
      storageFile: storageFile,
      legacyStorageFile: legacyFile,
    );

    final imported = await service.importLegacySnapshotFromContent('''
{
  "contexts": [
    {
      "session": {
        "id": "session-manual",
        "title": "手動インポート",
        "startedAt": 804427200
      },
      "laps": [],
      "splitAccumulationMode": "radio",
      "state": "idle"
    }
  ],
  "sessionOrder": ["session-manual"],
  "selectedSessionID": "session-manual"
}
''');

    expect(imported, isNotNull);
    expect(imported!.sessions.single.session?.title, '手動インポート');
  });
}
