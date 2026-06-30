import '../models/session_models.dart';

typedef IdGenerator = String Function();

class StopwatchController {
  StopwatchController({
    IdGenerator? idGenerator,
    StopwatchSnapshot? initialSnapshot,
  }) : _idGenerator = idGenerator ?? _defaultIdGenerator {
    if (initialSnapshot != null) {
      _restore(initialSnapshot);
    }
  }

  final IdGenerator _idGenerator;

  WorkSession? _session;
  List<WorkLap> _laps = [];
  String? _selectedLapId;
  Set<String> _activeLapIds = {};
  SplitAccumulationMode _splitAccumulationMode = SplitAccumulationMode.checkbox;
  SessionState _state = SessionState.idle;
  DateTime? _pauseStartedAt;
  int _lastDistributedWholeSeconds = 0;
  int _distributionCursor = 0;
  int _totalPausedSeconds = 0;

  WorkSession? get session => _session;
  List<WorkLap> get laps => List.unmodifiable(_laps);
  String? get selectedLapId => _selectedLapId;
  Set<String> get activeLapIds => Set.unmodifiable(_activeLapIds);
  SplitAccumulationMode get splitAccumulationMode => _splitAccumulationMode;
  SessionState get state => _state;
  DateTime? get pauseStartedAt => _pauseStartedAt;

  WorkLap? get currentLap {
    final selected = _selectedLapId;
    if (selected == null) {
      return null;
    }
    for (final lap in _laps) {
      if (lap.id == selected) {
        return lap;
      }
    }
    return null;
  }

  StopwatchSnapshot snapshot() {
    return StopwatchSnapshot(
      session: _session,
      laps: _laps,
      selectedLapId: _selectedLapId,
      activeLapIds: _activeLapIds,
      splitAccumulationMode: _splitAccumulationMode,
      state: _state,
      pauseStartedAt: _pauseStartedAt,
      lastDistributedWholeSeconds: _lastDistributedWholeSeconds,
      distributionCursor: _distributionCursor,
      totalPausedSeconds: _totalPausedSeconds,
    );
  }

  void startSession({
    SplitAccumulationMode defaultSplitAccumulationMode =
        SplitAccumulationMode.radio,
    required DateTime at,
  }) {
    switch (_state) {
      case SessionState.running:
        return;
      case SessionState.paused:
      case SessionState.stopped:
        if (_laps.isEmpty) {
          _activateIdleSession(at, defaultSplitAccumulationMode);
          return;
        }
        _resume(at);
        return;
      case SessionState.idle:
      case SessionState.finished:
        _activateIdleSession(at, defaultSplitAccumulationMode);
    }
  }

  void pauseSession({required DateTime at}) {
    if (_state != SessionState.running) {
      return;
    }

    _distributePendingWholeSeconds(until: at);
    _state = SessionState.paused;
    _pauseStartedAt = at;
  }

  void resumeSession({required DateTime at}) {
    if (_state != SessionState.paused && _state != SessionState.stopped) {
      return;
    }
    _resume(at);
  }

  void finishSession({required DateTime at}) {
    if (_state != SessionState.running && _state != SessionState.paused) {
      return;
    }

    final stoppedAt = _state == SessionState.paused
        ? (_pauseStartedAt ?? at)
        : at;
    if (_state == SessionState.running) {
      _distributePendingWholeSeconds(until: stoppedAt);
    }

    _state = SessionState.stopped;
    _pauseStartedAt = stoppedAt;
  }

  void finishLap({required DateTime at}) {
    if (_state != SessionState.running) {
      return;
    }
    final selected = _selectedLapId;
    final currentIndex = _laps.indexWhere((lap) => lap.id == selected);
    if (selected == null || currentIndex < 0 || _session == null) {
      return;
    }

    _distributePendingWholeSeconds(until: at);
    final previousOrder = _distributionOrder();
    final currentLap = _laps[currentIndex];
    if (currentLap.endedAt == null) {
      _laps[currentIndex] = currentLap.copyWith(endedAt: at);
    }

    final nextIndex =
        _laps.fold(0, (max, lap) => lap.index > max ? lap.index : max) + 1;
    final nextLap = WorkLap(
      id: _idGenerator(),
      sessionId: _session!.id,
      index: nextIndex,
      startedAt: at,
      accumulatedSeconds: 0,
      label: defaultLapLabel(nextIndex),
    );
    _laps = [..._laps, nextLap];
    _selectedLapId = nextLap.id;

    switch (_splitAccumulationMode) {
      case SplitAccumulationMode.radio:
        _activeLapIds = {nextLap.id};
        _distributionCursor = 0;
      case SplitAccumulationMode.checkbox:
        final lapIds = _laps.map((lap) => lap.id).toSet();
        final active = _activeLapIds.intersection(lapIds);
        _activeLapIds = {
          ...(active.isEmpty ? {nextLap.id} : active),
          nextLap.id,
        };
        final newOrder = _distributionOrder(
          mode: SplitAccumulationMode.checkbox,
        );
        _distributionCursor = _rebasedDistributionCursor(
          previousOrder: previousOrder,
          newOrder: newOrder,
          previousCursor: _distributionCursor,
        );
    }

    _lastDistributedWholeSeconds = _wholeElapsedSeconds(at);
  }

  void selectLap(String lapId, {required DateTime at}) {
    if (!_laps.any((lap) => lap.id == lapId) || _selectedLapId == lapId) {
      return;
    }

    if (_state == SessionState.running) {
      _distributePendingWholeSeconds(until: at);
      _selectedLapId = lapId;
      if (_splitAccumulationMode == SplitAccumulationMode.radio) {
        _activeLapIds = {lapId};
        _distributionCursor = 0;
      }
      _lastDistributedWholeSeconds = _wholeElapsedSeconds(at);
      return;
    }

    if (_state == SessionState.paused || _state == SessionState.stopped) {
      _selectedLapId = lapId;
      if (_splitAccumulationMode == SplitAccumulationMode.radio) {
        _activeLapIds = {lapId};
        _distributionCursor = 0;
      } else {
        final previousOrder = _distributionOrder(
          mode: SplitAccumulationMode.checkbox,
        );
        _activeLapIds = _normalizedActiveLapIds(
          _activeLapIds,
          selectedLapId: _selectedLapId,
          mode: SplitAccumulationMode.checkbox,
        );
        final newOrder = _distributionOrder(
          mode: SplitAccumulationMode.checkbox,
        );
        _distributionCursor = _rebasedDistributionCursor(
          previousOrder: previousOrder,
          newOrder: newOrder,
          previousCursor: _distributionCursor,
        );
      }
    }
  }

  void toggleLapActive(String lapId, {required DateTime at}) {
    if (_splitAccumulationMode != SplitAccumulationMode.checkbox ||
        !_laps.any((lap) => lap.id == lapId)) {
      return;
    }

    if (_state == SessionState.running) {
      _distributePendingWholeSeconds(until: at);
    }

    final previousOrder = _distributionOrder(
      mode: SplitAccumulationMode.checkbox,
    );
    final active = _normalizedActiveLapIds(
      _activeLapIds,
      selectedLapId: _selectedLapId,
      mode: SplitAccumulationMode.checkbox,
    );

    if (active.contains(lapId)) {
      if (active.length <= 1) {
        if (_state == SessionState.running) {
          _lastDistributedWholeSeconds = _wholeElapsedSeconds(at);
        }
        return;
      }
      active.remove(lapId);
    } else {
      active.add(lapId);
    }

    _activeLapIds = active;
    final newOrder = _distributionOrder(mode: SplitAccumulationMode.checkbox);
    _distributionCursor = _rebasedDistributionCursor(
      previousOrder: previousOrder,
      newOrder: newOrder,
      previousCursor: _distributionCursor,
    );
    if (_state == SessionState.running) {
      _lastDistributedWholeSeconds = _wholeElapsedSeconds(at);
    }
  }

  bool selectOrToggleLapForShortcut(int displayIndex, {required DateTime at}) {
    final lapId = _lapIdForShortcutDisplayIndex(displayIndex);
    if (lapId == null) {
      return false;
    }

    switch (_splitAccumulationMode) {
      case SplitAccumulationMode.radio:
        selectLap(lapId, at: at);
      case SplitAccumulationMode.checkbox:
        toggleLapActive(lapId, at: at);
        selectLap(lapId, at: at);
    }
    return true;
  }

  bool moveSelectedLapForShortcut(int offset, {required DateTime at}) {
    if (offset == 0) {
      return false;
    }
    final selected = _selectedLapId;
    if (selected == null) {
      return false;
    }
    final currentIndex = _laps.indexWhere((lap) => lap.id == selected);
    if (currentIndex < 0) {
      return false;
    }
    final targetIndex = currentIndex + offset;
    if (targetIndex < 0 || targetIndex >= _laps.length) {
      return false;
    }

    selectLap(_laps[targetIndex].id, at: at);
    return true;
  }

  void setSplitAccumulationMode(
    SplitAccumulationMode mode, {
    required DateTime at,
  }) {
    if (_splitAccumulationMode == mode) {
      return;
    }

    if (_state == SessionState.running) {
      _distributePendingWholeSeconds(until: at);
    }

    final previousOrder = _distributionOrder(mode: _splitAccumulationMode);
    _splitAccumulationMode = mode;
    _activeLapIds = _normalizedActiveLapIds(
      _activeLapIds,
      selectedLapId: _selectedLapId,
      mode: mode,
    );
    final newOrder = _distributionOrder(mode: mode);
    _distributionCursor = _rebasedDistributionCursor(
      previousOrder: previousOrder,
      newOrder: newOrder,
      previousCursor: _distributionCursor,
    );
    if (_state == SessionState.running) {
      _lastDistributedWholeSeconds = _wholeElapsedSeconds(at);
    }
  }

  void updateSessionTitle(String title) {
    final trimmed = title.trim();
    final session = _session;
    if (session == null || trimmed.isEmpty) {
      return;
    }
    _session = session.copyWith(title: trimmed);
  }

  void updateLapLabel(String lapId, String label) {
    final index = _laps.indexWhere((lap) => lap.id == lapId);
    if (index < 0) {
      return;
    }
    final trimmed = _singleLineLabel(label);
    final lap = _laps[index];
    _laps[index] = lap.copyWith(
      label: trimmed.isEmpty ? defaultLapLabel(lap.index) : trimmed,
    );
  }

  void updateLapMemo(String lapId, String memo) {
    final index = _laps.indexWhere((lap) => lap.id == lapId);
    if (index < 0) {
      return;
    }
    _laps[index] = _laps[index].copyWith(memo: memo);
  }

  void reset({required DateTime at}) {
    _session = _session?.copyWith(startedAt: at, endedAt: null);
    _laps = [];
    _selectedLapId = null;
    _activeLapIds = {};
    _state = SessionState.idle;
    _pauseStartedAt = null;
    _lastDistributedWholeSeconds = 0;
    _distributionCursor = 0;
    _totalPausedSeconds = 0;
  }

  int elapsedSessionSeconds({required DateTime at}) {
    final session = _session;
    if (session == null) {
      return 0;
    }

    final end = _resolvedEndDate(at);
    if (!end.isAfter(session.startedAt)) {
      return 0;
    }

    return (end.difference(session.startedAt).inMilliseconds ~/ 1000) -
        _totalPausedSeconds;
  }

  int elapsedLapSeconds(WorkLap lap, {required DateTime at}) {
    var elapsed = lap.accumulatedSeconds.clamp(0, 1 << 53);
    if (_state != SessionState.running) {
      return elapsed;
    }

    final pending = _pendingDistribution(at: at);
    final targetIndex = pending.order.indexOf(lap.id);
    if (targetIndex < 0 || pending.delta <= 0) {
      return elapsed;
    }

    elapsed += pending.hitCount(targetIndex);
    return elapsed;
  }

  Map<String, int> displayedLapSecondsMap({required DateTime at}) {
    if (_laps.isEmpty) {
      return {};
    }

    final result = {
      for (final lap in _laps) lap.id: lap.accumulatedSeconds.clamp(0, 1 << 53),
    };

    if (_state != SessionState.running) {
      return result;
    }

    final pending = _pendingDistribution(at: at);
    if (pending.delta <= 0 || pending.order.isEmpty) {
      return result;
    }

    for (var index = 0; index < pending.order.length; index += 1) {
      final increment = pending.hitCount(index);
      if (increment > 0) {
        final lapId = pending.order[index];
        result[lapId] = (result[lapId] ?? 0) + increment;
      }
    }
    return result;
  }

  String defaultLapLabel(int index) => '作業$index';

  void _restore(StopwatchSnapshot snapshot) {
    _session = snapshot.session;
    _laps = [...snapshot.laps];
    _selectedLapId = _normalizedSelectedLapId(snapshot.selectedLapId);
    _splitAccumulationMode = snapshot.splitAccumulationMode;
    _activeLapIds = _normalizedActiveLapIds(
      snapshot.activeLapIds,
      selectedLapId: _selectedLapId,
      mode: _splitAccumulationMode,
    );
    _state = snapshot.state;
    _pauseStartedAt = snapshot.pauseStartedAt;
    _lastDistributedWholeSeconds = snapshot.lastDistributedWholeSeconds.clamp(
      0,
      1 << 53,
    );
    _distributionCursor = _normalizedDistributionCursor(
      snapshot.distributionCursor,
      _distributionOrder().length,
    );
    _totalPausedSeconds = snapshot.totalPausedSeconds.clamp(0, 1 << 53);
  }

  void _activateIdleSession(
    DateTime at,
    SplitAccumulationMode splitAccumulationMode,
  ) {
    final session = _session == null
        ? WorkSession(
            id: _idGenerator(),
            title: _defaultSessionTitle(at),
            startedAt: at,
          )
        : _session!.copyWith(startedAt: at, endedAt: null);
    final initialLap = WorkLap(
      id: _idGenerator(),
      sessionId: session.id,
      index: 1,
      startedAt: at,
      accumulatedSeconds: 0,
      label: defaultLapLabel(1),
    );

    _session = session;
    _laps = [initialLap];
    _selectedLapId = initialLap.id;
    _activeLapIds = {initialLap.id};
    _splitAccumulationMode = splitAccumulationMode;
    _state = SessionState.running;
    _pauseStartedAt = null;
    _lastDistributedWholeSeconds = 0;
    _distributionCursor = 0;
    _totalPausedSeconds = 0;
  }

  void _resume(DateTime at) {
    if (_state != SessionState.paused && _state != SessionState.stopped) {
      return;
    }
    final pausedAt = _pauseStartedAt ?? at;
    final resumedAt = at.isAfter(pausedAt) ? at : pausedAt;
    _totalPausedSeconds +=
        resumedAt.difference(pausedAt).inMilliseconds ~/ 1000;
    _pauseStartedAt = null;
    _state = SessionState.running;
    _lastDistributedWholeSeconds = _wholeElapsedSeconds(resumedAt);
    _distributionCursor = _normalizedDistributionCursor(
      _distributionCursor,
      _distributionOrder().length,
    );
  }

  void _distributePendingWholeSeconds({
    required DateTime until,
    SplitAccumulationMode? mode,
  }) {
    if (_state != SessionState.running) {
      return;
    }

    final pending = _pendingDistribution(at: until, mode: mode);
    if (pending.delta <= 0) {
      return;
    }

    if (pending.order.isEmpty) {
      _lastDistributedWholeSeconds = pending.currentWhole;
      _distributionCursor = 0;
      return;
    }

    final lapIndexById = {
      for (var index = 0; index < _laps.length; index += 1)
        _laps[index].id: index,
    };

    for (var index = 0; index < pending.order.length; index += 1) {
      final increment = pending.hitCount(index);
      if (increment <= 0) {
        continue;
      }
      final lapIndex = lapIndexById[pending.order[index]];
      if (lapIndex == null) {
        continue;
      }
      final lap = _laps[lapIndex];
      _laps[lapIndex] = lap.copyWith(
        accumulatedSeconds: lap.accumulatedSeconds + increment,
      );
    }

    _lastDistributedWholeSeconds = pending.currentWhole;
    _distributionCursor = pending.nextCursor;
  }

  _PendingDistribution _pendingDistribution({
    required DateTime at,
    SplitAccumulationMode? mode,
  }) {
    final currentWhole = _wholeElapsedSeconds(at);
    final delta = (currentWhole - _lastDistributedWholeSeconds).clamp(
      0,
      1 << 53,
    );
    final order = _distributionOrder(mode: mode);
    final cursor = _normalizedDistributionCursor(
      _distributionCursor,
      order.length,
    );
    return _PendingDistribution(
      order: order,
      cursor: cursor,
      delta: delta,
      currentWhole: currentWhole,
    );
  }

  int _wholeElapsedSeconds(DateTime at) {
    return elapsedSessionSeconds(at: at).clamp(0, 1 << 53);
  }

  DateTime _resolvedEndDate(DateTime referenceDate) {
    final endedAt = _session?.endedAt;
    if (endedAt != null) {
      return endedAt;
    }
    if ((_state == SessionState.paused || _state == SessionState.stopped) &&
        _pauseStartedAt != null &&
        referenceDate.isAfter(_pauseStartedAt!)) {
      return _pauseStartedAt!;
    }
    return referenceDate;
  }

  List<String> _distributionOrder({SplitAccumulationMode? mode}) {
    final effectiveMode = mode ?? _splitAccumulationMode;
    switch (effectiveMode) {
      case SplitAccumulationMode.radio:
        final selected = _selectedLapId;
        if (selected == null || !_laps.any((lap) => lap.id == selected)) {
          return [];
        }
        return [selected];
      case SplitAccumulationMode.checkbox:
        final normalized = _normalizedActiveLapIds(
          _activeLapIds,
          selectedLapId: _selectedLapId,
          mode: SplitAccumulationMode.checkbox,
        );
        return [
          for (final lap in _laps)
            if (normalized.contains(lap.id)) lap.id,
        ];
    }
  }

  String? _normalizedSelectedLapId(String? selectedLapId) {
    if (_laps.isEmpty) {
      return null;
    }
    if (selectedLapId != null && _laps.any((lap) => lap.id == selectedLapId)) {
      return selectedLapId;
    }
    final unfinished = _laps.where((lap) => lap.endedAt == null).toList()
      ..sort((a, b) => b.index.compareTo(a.index));
    if (unfinished.isNotEmpty) {
      return unfinished.first.id;
    }
    final sorted = [..._laps]..sort((a, b) => b.index.compareTo(a.index));
    return sorted.first.id;
  }

  Set<String> _normalizedActiveLapIds(
    Set<String> activeLapIds, {
    required String? selectedLapId,
    required SplitAccumulationMode mode,
  }) {
    if (_laps.isEmpty) {
      return {};
    }

    switch (mode) {
      case SplitAccumulationMode.radio:
        if (selectedLapId != null &&
            _laps.any((lap) => lap.id == selectedLapId)) {
          return {selectedLapId};
        }
        return {};
      case SplitAccumulationMode.checkbox:
        final lapIds = _laps.map((lap) => lap.id).toSet();
        final filtered = activeLapIds.intersection(lapIds);
        if (filtered.isNotEmpty) {
          return filtered;
        }
        if (selectedLapId != null && lapIds.contains(selectedLapId)) {
          return {selectedLapId};
        }
        return {_laps.reduce((a, b) => a.index > b.index ? a : b).id};
    }
  }

  int _normalizedDistributionCursor(int cursor, int count) {
    if (count <= 0) {
      return 0;
    }
    return ((cursor % count) + count) % count;
  }

  int _rebasedDistributionCursor({
    required List<String> previousOrder,
    required List<String> newOrder,
    required int previousCursor,
  }) {
    if (newOrder.isEmpty || previousOrder.isEmpty) {
      return 0;
    }

    final normalizedPreviousCursor = _normalizedDistributionCursor(
      previousCursor,
      previousOrder.length,
    );
    final nextTargetId = previousOrder[normalizedPreviousCursor];
    final newIndex = newOrder.indexOf(nextTargetId);
    if (newIndex >= 0) {
      return newIndex;
    }
    return _normalizedDistributionCursor(previousCursor, newOrder.length);
  }

  String _defaultSessionTitle(DateTime date) {
    return '${date.year}/${date.month}/${date.day}';
  }

  String? _lapIdForShortcutDisplayIndex(int displayIndex) {
    if (_laps.isEmpty) {
      return null;
    }
    if (displayIndex == 0) {
      return _laps.last.id;
    }
    final targetIndex = displayIndex - 1;
    if (targetIndex < 0 || targetIndex >= _laps.length) {
      return null;
    }
    return _laps[targetIndex].id;
  }
}

class _PendingDistribution {
  const _PendingDistribution({
    required this.order,
    required this.cursor,
    required this.delta,
    required this.currentWhole,
  });

  final List<String> order;
  final int cursor;
  final int delta;
  final int currentWhole;

  int hitCount(int targetIndex) {
    if (delta <= 0 || order.isEmpty) {
      return 0;
    }
    if (targetIndex < 0 || targetIndex >= order.length) {
      return 0;
    }

    final count = order.length;
    final fullCycles = delta ~/ count;
    final remainder = delta % count;
    final offset = (targetIndex - cursor + count) % count;
    return fullCycles + (offset < remainder ? 1 : 0);
  }

  int get nextCursor {
    if (order.isEmpty) {
      return 0;
    }
    return (cursor + (delta % order.length)) % order.length;
  }
}

int _idCounter = 0;

String _defaultIdGenerator() {
  _idCounter += 1;
  return 'id-$_idCounter';
}

String _singleLineLabel(String value) {
  return value.replaceAll(RegExp(r'[\r\n]+'), '').trim();
}
