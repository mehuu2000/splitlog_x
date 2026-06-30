import 'package:flutter_test/flutter_test.dart';
import 'package:splitlog_x/core/models/session_models.dart';
import 'package:splitlog_x/core/services/stopwatch_controller.dart';

void main() {
  DateTime at(int seconds) => DateTime.utc(2026, 6, 30, 12, 0, seconds);

  StopwatchController controller() {
    var id = 0;
    return StopwatchController(
      idGenerator: () {
        id += 1;
        return 'id-$id';
      },
    );
  }

  test('starts a session with an initial lap', () {
    final stopwatch = controller();

    stopwatch.startSession(
      defaultSplitAccumulationMode: SplitAccumulationMode.radio,
      at: at(0),
    );

    expect(stopwatch.state, SessionState.running);
    expect(stopwatch.session?.title, '2026/6/30');
    expect(stopwatch.laps, hasLength(1));
    expect(stopwatch.laps.single.label, '作業1');
    expect(stopwatch.selectedLapId, stopwatch.laps.single.id);
    expect(stopwatch.activeLapIds, {stopwatch.laps.single.id});
    expect(stopwatch.elapsedSessionSeconds(at: at(5)), 5);
    expect(stopwatch.displayedLapSecondsMap(at: at(5)), {
      stopwatch.laps.single.id: 5,
    });
  });

  test('radio mode distributes elapsed seconds to the selected lap', () {
    final stopwatch = controller();
    stopwatch.startSession(
      defaultSplitAccumulationMode: SplitAccumulationMode.radio,
      at: at(0),
    );

    stopwatch.finishLap(at: at(5));
    final firstLap = stopwatch.laps[0];
    final secondLap = stopwatch.laps[1];

    expect(firstLap.accumulatedSeconds, 5);
    expect(firstLap.endedAt, at(5));
    expect(stopwatch.selectedLapId, secondLap.id);
    expect(stopwatch.displayedLapSecondsMap(at: at(8)), {
      firstLap.id: 5,
      secondLap.id: 3,
    });
  });

  test(
    'checkbox mode keeps checked laps active and distributes round-robin',
    () {
      final stopwatch = controller();
      stopwatch.startSession(
        defaultSplitAccumulationMode: SplitAccumulationMode.checkbox,
        at: at(0),
      );

      stopwatch.finishLap(at: at(3));
      final firstLap = stopwatch.laps[0];
      final secondLap = stopwatch.laps[1];

      expect(stopwatch.activeLapIds, {firstLap.id, secondLap.id});
      expect(stopwatch.displayedLapSecondsMap(at: at(7)), {
        firstLap.id: 5,
        secondLap.id: 2,
      });
    },
  );

  test('displayed lap seconds sum matches total elapsed seconds', () {
    final stopwatch = controller();
    stopwatch.startSession(
      defaultSplitAccumulationMode: SplitAccumulationMode.checkbox,
      at: at(0),
    );

    stopwatch.finishLap(at: at(3));
    stopwatch.finishLap(at: at(8));
    stopwatch.toggleLapActive(stopwatch.laps[0].id, at: at(10));
    stopwatch.selectLap(stopwatch.laps[1].id, at: at(12));

    final displayed = stopwatch.displayedLapSecondsMap(at: at(25));
    final splitTotal = displayed.values.fold(
      0,
      (sum, seconds) => sum + seconds,
    );

    expect(splitTotal, stopwatch.elapsedSessionSeconds(at: at(25)));
  });

  test('pause and resume exclude paused duration from elapsed time', () {
    final stopwatch = controller();
    stopwatch.startSession(
      defaultSplitAccumulationMode: SplitAccumulationMode.radio,
      at: at(0),
    );

    stopwatch.pauseSession(at: at(5));
    expect(stopwatch.state, SessionState.paused);
    expect(stopwatch.elapsedSessionSeconds(at: at(12)), 5);

    stopwatch.resumeSession(at: at(15));
    expect(stopwatch.state, SessionState.running);
    expect(stopwatch.elapsedSessionSeconds(at: at(20)), 10);
    expect(stopwatch.displayedLapSecondsMap(at: at(20)), {
      stopwatch.laps.single.id: 10,
    });
  });

  test('lap label updates remove embedded line breaks', () {
    final stopwatch = controller();
    stopwatch.startSession(
      defaultSplitAccumulationMode: SplitAccumulationMode.radio,
      at: at(0),
    );

    stopwatch.updateLapLabel(stopwatch.laps.single.id, 'websocket, push動\n作確認');

    expect(stopwatch.laps.single.label, 'websocket, push動作確認');
  });

  test('snapshot JSON round-trips core state', () {
    final stopwatch = controller();
    stopwatch.startSession(
      defaultSplitAccumulationMode: SplitAccumulationMode.checkbox,
      at: at(0),
    );
    stopwatch.finishLap(at: at(2));
    stopwatch.pauseSession(at: at(5));

    final restored = StopwatchController(
      idGenerator: () => 'restored-id',
      initialSnapshot: StopwatchSnapshot.fromJson(
        stopwatch.snapshot().toJson(),
      ),
    );

    expect(restored.state, SessionState.paused);
    expect(restored.session?.title, '2026/6/30');
    expect(restored.laps, hasLength(2));
    expect(restored.activeLapIds, stopwatch.activeLapIds);
    expect(restored.displayedLapSecondsMap(at: at(30)), {
      restored.laps[0].id: 4,
      restored.laps[1].id: 1,
    });
  });
}
