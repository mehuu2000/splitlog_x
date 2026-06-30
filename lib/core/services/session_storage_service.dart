import 'dart:convert';
import 'dart:io';

import '../models/session_models.dart';

class SplitLogSettingsSnapshot {
  const SplitLogSettingsSnapshot({
    this.isLocked = false,
    this.isMonochrome = false,
    this.ringHoursPerCycle = 4,
    this.defaultSplitMode = SplitAccumulationMode.radio,
    this.summaryMemoFormat = 'bulleted',
    this.summaryTimeFormat = 'decimalHours',
  });

  final bool isLocked;
  final bool isMonochrome;
  final int ringHoursPerCycle;
  final SplitAccumulationMode defaultSplitMode;
  final String summaryMemoFormat;
  final String summaryTimeFormat;

  Map<String, Object?> toJson() {
    return {
      'isLocked': isLocked,
      'isMonochrome': isMonochrome,
      'ringHoursPerCycle': ringHoursPerCycle,
      'defaultSplitMode': defaultSplitMode.name,
      'summaryMemoFormat': summaryMemoFormat,
      'summaryTimeFormat': summaryTimeFormat,
    };
  }

  static SplitLogSettingsSnapshot fromJson(Map<String, Object?> json) {
    return SplitLogSettingsSnapshot(
      isLocked: json['isLocked'] as bool? ?? false,
      isMonochrome: json['isMonochrome'] as bool? ?? false,
      ringHoursPerCycle: _intValue(
        json['ringHoursPerCycle'],
        fallback: 4,
      ).clamp(1, 24),
      defaultSplitMode: SplitAccumulationMode.fromJson(
        json['defaultSplitMode'],
      ),
      summaryMemoFormat: json['summaryMemoFormat'] as String? ?? 'bulleted',
      summaryTimeFormat: json['summaryTimeFormat'] as String? ?? 'decimalHours',
    );
  }
}

class SplitLogStorageSnapshot {
  const SplitLogStorageSnapshot({
    required this.savedAt,
    required this.sessions,
    required this.selectedSessionIndex,
    required this.settings,
    this.schemaVersion = currentSchemaVersion,
  });

  static const currentSchemaVersion = 1;

  final int schemaVersion;
  final DateTime savedAt;
  final List<StopwatchSnapshot> sessions;
  final int selectedSessionIndex;
  final SplitLogSettingsSnapshot settings;

  Map<String, Object?> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'savedAt': savedAt.toIso8601String(),
      'sessions': sessions.map((session) => session.toJson()).toList(),
      'selectedSessionIndex': selectedSessionIndex,
      'settings': settings.toJson(),
    };
  }

  static SplitLogStorageSnapshot fromJson(Map<String, Object?> json) {
    final sessions = switch (json['sessions']) {
      final List<Object?> values =>
        values
            .whereType<Map<Object?, Object?>>()
            .map((value) => StopwatchSnapshot.fromJson(_objectMap(value)))
            .toList(),
      _ => const <StopwatchSnapshot>[],
    };

    return SplitLogStorageSnapshot(
      schemaVersion: _intValue(json['schemaVersion'], fallback: 1),
      savedAt: _dateTimeValue(json['savedAt']),
      sessions: sessions,
      selectedSessionIndex: _intValue(json['selectedSessionIndex']),
      settings: switch (json['settings']) {
        final Map<Object?, Object?> value => SplitLogSettingsSnapshot.fromJson(
          _objectMap(value),
        ),
        _ => const SplitLogSettingsSnapshot(),
      },
    );
  }

  static SplitLogStorageSnapshot fromLegacyJson(Map<String, Object?> json) {
    final contextsById = <String, Map<String, Object?>>{};
    for (final context in switch (json['contexts']) {
      final List<Object?> values => values.whereType<Map<Object?, Object?>>(),
      _ => const Iterable<Map<Object?, Object?>>.empty(),
    }) {
      final mapped = _objectMap(context);
      final session = mapped['session'];
      if (session is Map<Object?, Object?>) {
        final id = session['id'];
        if (id is String) {
          contextsById[id] = mapped;
        }
      }
    }

    final orderedIds = switch (json['sessionOrder']) {
      final List<Object?> values => values.whereType<String>().toList(),
      _ => const <String>[],
    };
    final contexts = [
      for (final id in orderedIds)
        if (contextsById.containsKey(id)) contextsById.remove(id)!,
      ...contextsById.values,
    ];
    final sessions = contexts.map(StopwatchSnapshot.fromJson).toList();
    final selectedSessionId = json['selectedSessionID'] as String?;
    final selectedIndex = selectedSessionId == null
        ? 0
        : contexts.indexWhere((context) {
            final session = context['session'];
            return session is Map<Object?, Object?> &&
                session['id'] == selectedSessionId;
          });

    return SplitLogStorageSnapshot(
      schemaVersion: currentSchemaVersion,
      savedAt: DateTime.now(),
      sessions: sessions,
      selectedSessionIndex: selectedIndex < 0 ? 0 : selectedIndex,
      settings: const SplitLogSettingsSnapshot(),
    );
  }
}

class SessionStorageService {
  SessionStorageService({File? storageFile, File? legacyStorageFile})
    : _storageFile =
          storageFile ?? File('${_storageDirectory().path}/sessions.json'),
      _legacyStorageFiles = legacyStorageFile == null
          ? _legacyFiles()
          : [legacyStorageFile];

  final File _storageFile;
  final List<File> _legacyStorageFiles;

  Future<SplitLogStorageSnapshot?> load() async {
    if (!await _storageFile.exists()) {
      return null;
    }

    final json = await _readJsonObject(_storageFile);
    if (json == null) {
      return null;
    }
    return SplitLogStorageSnapshot.fromJson(json);
  }

  Future<void> save(SplitLogStorageSnapshot snapshot) async {
    await _storageFile.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await _storageFile.writeAsString('${encoder.convert(snapshot.toJson())}\n');
  }

  Future<void> delete() async {
    if (await _storageFile.exists()) {
      await _storageFile.delete();
    }
  }

  Future<bool> legacySnapshotExists() async {
    for (final file in _legacyStorageFiles) {
      if (await _exists(file)) {
        return true;
      }
    }
    return false;
  }

  Future<SplitLogStorageSnapshot?> importLegacySnapshot() async {
    for (final file in _legacyStorageFiles) {
      if (!await _exists(file)) {
        continue;
      }
      final json = await _readJsonObject(file);
      if (json == null) {
        continue;
      }
      final snapshot = SplitLogStorageSnapshot.fromLegacyJson(json);
      if (snapshot.sessions.isNotEmpty) {
        return snapshot;
      }
    }
    return null;
  }

  Future<Map<String, Object?>?> _readJsonObject(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<Object?, Object?>) {
        return null;
      }
      return _objectMap(decoded);
    } on Object {
      return null;
    }
  }

  Future<bool> _exists(File file) async {
    try {
      return await file.exists();
    } on Object {
      return false;
    }
  }

  static Directory _storageDirectory() {
    final home = Platform.environment['HOME'];
    if (Platform.isMacOS && home != null) {
      return Directory('$home/Library/Application Support/SplitLog_x');
    }

    final appData = Platform.environment['APPDATA'];
    if (Platform.isWindows && appData != null) {
      return Directory('$appData/SplitLog_x');
    }

    return Directory('${Directory.current.path}/.splitlog_x');
  }

  static List<File> _legacyFiles() {
    if (!Platform.isMacOS) {
      return const [];
    }
    final paths = <String>{};
    for (final home in _homeCandidates()) {
      paths.add('$home/Library/Application Support/SplitLog/sessions.json');
      paths.add(
        '$home/Library/Containers/hamachi.SplitLog/Data/Library/Application Support/SplitLog/sessions.json',
      );
    }
    return [for (final path in paths) File(path)];
  }

  static List<String> _homeCandidates() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      return const [];
    }

    final candidates = <String>[home];
    const sandboxMarker = '/Library/Containers/';
    final markerIndex = home.indexOf(sandboxMarker);
    if (markerIndex > 0) {
      final userHome = home.substring(0, markerIndex);
      if (!candidates.contains(userHome)) {
        candidates.add(userHome);
      }
    }
    return candidates;
  }
}

int _intValue(Object? value, {int fallback = 0}) {
  return switch (value) {
    final int intValue => intValue,
    final double doubleValue => doubleValue.floor(),
    _ => fallback,
  };
}

DateTime _dateTimeValue(Object? value) {
  return switch (value) {
    final String stringValue => DateTime.parse(stringValue),
    final int intValue => _dateTimeFromAppleReferenceSeconds(
      intValue.toDouble(),
    ),
    final double doubleValue => _dateTimeFromAppleReferenceSeconds(doubleValue),
    _ => DateTime.fromMillisecondsSinceEpoch(0),
  };
}

DateTime _dateTimeFromAppleReferenceSeconds(double seconds) {
  const appleReferenceUnixMilliseconds = 978307200000;
  return DateTime.fromMillisecondsSinceEpoch(
    appleReferenceUnixMilliseconds + (seconds * 1000).round(),
    isUtc: true,
  ).toLocal();
}

Map<String, Object?> _objectMap(Map<Object?, Object?> value) {
  return {
    for (final entry in value.entries)
      if (entry.key is String) entry.key! as String: entry.value,
  };
}
