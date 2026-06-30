enum SessionState {
  idle,
  running,
  paused,
  stopped,
  finished;

  static SessionState fromJson(Object? value) {
    return SessionState.values.firstWhere(
      (state) => state.name == value,
      orElse: () => SessionState.idle,
    );
  }
}

enum SplitAccumulationMode {
  radio,
  checkbox;

  static SplitAccumulationMode fromJson(Object? value) {
    return SplitAccumulationMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => SplitAccumulationMode.radio,
    );
  }
}

class WorkSession {
  const WorkSession({
    required this.id,
    required this.title,
    required this.startedAt,
    this.endedAt,
  });

  final String id;
  final String title;
  final DateTime startedAt;
  final DateTime? endedAt;

  WorkSession copyWith({
    String? id,
    String? title,
    DateTime? startedAt,
    Object? endedAt = _notProvided,
  }) {
    return WorkSession(
      id: id ?? this.id,
      title: title ?? this.title,
      startedAt: startedAt ?? this.startedAt,
      endedAt: identical(endedAt, _notProvided)
          ? this.endedAt
          : endedAt as DateTime?,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'title': title,
      'startedAt': startedAt.toIso8601String(),
      if (endedAt != null) 'endedAt': endedAt!.toIso8601String(),
    };
  }

  static WorkSession fromJson(Map<String, Object?> json) {
    return WorkSession(
      id: json['id'] as String,
      title: json['title'] as String,
      startedAt: DateTime.parse(json['startedAt'] as String),
      endedAt: switch (json['endedAt']) {
        final String value => DateTime.parse(value),
        _ => null,
      },
    );
  }
}

class WorkLap {
  const WorkLap({
    required this.id,
    required this.sessionId,
    required this.index,
    required this.startedAt,
    required this.accumulatedSeconds,
    required this.label,
    this.endedAt,
    this.memo = '',
  });

  final String id;
  final String sessionId;
  final int index;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int accumulatedSeconds;
  final String label;
  final String memo;

  WorkLap copyWith({
    String? id,
    String? sessionId,
    int? index,
    DateTime? startedAt,
    Object? endedAt = _notProvided,
    int? accumulatedSeconds,
    String? label,
    String? memo,
  }) {
    return WorkLap(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      index: index ?? this.index,
      startedAt: startedAt ?? this.startedAt,
      endedAt: identical(endedAt, _notProvided)
          ? this.endedAt
          : endedAt as DateTime?,
      accumulatedSeconds: accumulatedSeconds ?? this.accumulatedSeconds,
      label: label ?? this.label,
      memo: memo ?? this.memo,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'sessionId': sessionId,
      'index': index,
      'startedAt': startedAt.toIso8601String(),
      if (endedAt != null) 'endedAt': endedAt!.toIso8601String(),
      'accumulatedDuration': accumulatedSeconds,
      'label': label,
      'memo': memo,
    };
  }

  static WorkLap fromJson(Map<String, Object?> json) {
    return WorkLap(
      id: json['id'] as String,
      sessionId: json['sessionId'] as String,
      index: json['index'] as int,
      startedAt: DateTime.parse(json['startedAt'] as String),
      endedAt: switch (json['endedAt']) {
        final String value => DateTime.parse(value),
        _ => null,
      },
      accumulatedSeconds: _durationSeconds(json['accumulatedDuration']),
      label: json['label'] as String,
      memo: json['memo'] as String? ?? '',
    );
  }
}

class StopwatchSnapshot {
  const StopwatchSnapshot({
    required this.session,
    required this.laps,
    required this.selectedLapId,
    required this.activeLapIds,
    required this.splitAccumulationMode,
    required this.state,
    required this.pauseStartedAt,
    required this.lastDistributedWholeSeconds,
    required this.distributionCursor,
    required this.totalPausedSeconds,
  });

  final WorkSession? session;
  final List<WorkLap> laps;
  final String? selectedLapId;
  final Set<String> activeLapIds;
  final SplitAccumulationMode splitAccumulationMode;
  final SessionState state;
  final DateTime? pauseStartedAt;
  final int lastDistributedWholeSeconds;
  final int distributionCursor;
  final int totalPausedSeconds;

  Map<String, Object?> toJson() {
    return {
      'session': session?.toJson(),
      'laps': laps.map((lap) => lap.toJson()).toList(),
      'selectedLapID': selectedLapId,
      'activeLapIDs': activeLapIds.toList(),
      'splitAccumulationMode': splitAccumulationMode.name,
      'state': state.name,
      if (pauseStartedAt != null)
        'pauseStartedAt': pauseStartedAt!.toIso8601String(),
      'lastDistributedWholeSeconds': lastDistributedWholeSeconds,
      'distributionCursor': distributionCursor,
      'totalPausedDuration': totalPausedSeconds,
    };
  }

  static StopwatchSnapshot fromJson(Map<String, Object?> json) {
    return StopwatchSnapshot(
      session: switch (json['session']) {
        final Map<String, Object?> value => WorkSession.fromJson(value),
        _ => null,
      },
      laps: switch (json['laps']) {
        final List<Object?> values =>
          values.cast<Map<String, Object?>>().map(WorkLap.fromJson).toList(),
        _ => const [],
      },
      selectedLapId: json['selectedLapID'] as String?,
      activeLapIds: switch (json['activeLapIDs']) {
        final List<Object?> values => values.cast<String>().toSet(),
        _ => const <String>{},
      },
      splitAccumulationMode: SplitAccumulationMode.fromJson(
        json['splitAccumulationMode'],
      ),
      state: SessionState.fromJson(json['state']),
      pauseStartedAt: switch (json['pauseStartedAt']) {
        final String value => DateTime.parse(value),
        _ => null,
      },
      lastDistributedWholeSeconds: _intValue(
        json['lastDistributedWholeSeconds'],
      ),
      distributionCursor: _intValue(json['distributionCursor']),
      totalPausedSeconds: _durationSeconds(json['totalPausedDuration']),
    );
  }
}

const Object _notProvided = Object();

int _intValue(Object? value) {
  return switch (value) {
    final int intValue => intValue,
    final double doubleValue => doubleValue.floor(),
    _ => 0,
  };
}

int _durationSeconds(Object? value) {
  return _intValue(value).clamp(0, 1 << 53);
}
