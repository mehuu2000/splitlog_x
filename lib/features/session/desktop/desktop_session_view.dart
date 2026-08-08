import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/session_models.dart';
import '../../../core/models/summary_format.dart';
import '../../../core/services/session_storage_service.dart';
import '../../../core/services/stopwatch_controller.dart';

enum _PreviewOverlay {
  none,
  sessionList,
  resetConfirmation,
  deleteConfirmation,
  memo,
  summary,
  settings,
  help,
  guide,
  contact,
  legacyImport,
  legacyImportMissing,
}

enum _SummaryTimeFormat {
  decimalHours,
  decimalHoursPrecise,
  hourMinute;

  String get optionLabel => switch (this) {
    _SummaryTimeFormat.hourMinute => '時間',
    _SummaryTimeFormat.decimalHours => 'h（小数第1位まで）',
    _SummaryTimeFormat.decimalHoursPrecise => 'h（小数第2位まで）',
  };
}

const _summaryTimeFormatOptions = [
  _SummaryTimeFormat.hourMinute,
  _SummaryTimeFormat.decimalHours,
  _SummaryTimeFormat.decimalHoursPrecise,
];

enum _ToastStyle { success, error }

enum _SettingsStorageAction {
  deleteSessionData,
  deleteLapData,
  resetSettings,
  initializeAllData;

  String get title => switch (this) {
    _SettingsStorageAction.deleteSessionData => 'セッション情報を削除しますか？',
    _SettingsStorageAction.deleteLapData => 'Split情報を削除しますか？',
    _SettingsStorageAction.resetSettings => '設定のみ初期化しますか？',
    _SettingsStorageAction.initializeAllData => '全データを初期化しますか？',
  };

  String get message => switch (this) {
    _SettingsStorageAction.deleteSessionData => '全セッション・Split・メモを削除します。',
    _SettingsStorageAction.deleteLapData => '全セッションのSplit・メモを削除します（セッション名は保持）。',
    _SettingsStorageAction.resetSettings => 'アプリ設定のみをデフォルトに戻します。',
    _SettingsStorageAction.initializeAllData => '全データと設定を削除して初期状態に戻します。',
  };

  String get confirmTitle => switch (this) {
    _SettingsStorageAction.deleteSessionData ||
    _SettingsStorageAction.deleteLapData => '削除',
    _SettingsStorageAction.resetSettings => 'リセット',
    _SettingsStorageAction.initializeAllData => '初期化',
  };

  bool get isDestructive => switch (this) {
    _SettingsStorageAction.deleteSessionData ||
    _SettingsStorageAction.deleteLapData ||
    _SettingsStorageAction.initializeAllData => true,
    _SettingsStorageAction.resetSettings => false,
  };
}

_SummaryTimeFormat _summaryTimeFormatFromName(String value) {
  return _SummaryTimeFormat.values.firstWhere(
    (format) => format.name == value,
    orElse: () => _SummaryTimeFormat.decimalHours,
  );
}

List<SummaryFormatDefinition> _upsertCustomSummaryFormat(
  List<SummaryFormatDefinition> formats,
  SummaryFormatDefinition format,
) {
  final existingIndex = formats.indexWhere(
    (candidate) => candidate.id == format.id,
  );
  if (existingIndex < 0) {
    return [...formats, format];
  }
  return [
    for (var index = 0; index < formats.length; index += 1)
      if (index == existingIndex) format else formats[index],
  ];
}

SummaryFormatDefinition _createCustomSummaryFormatDraft(
  List<SummaryFormatDefinition> formats,
) {
  var suffix = 1;
  final usedNames = formats.map((format) => format.name).toSet();
  while (usedNames.contains('カスタム$suffix')) {
    suffix += 1;
  }
  final timestamp = DateTime.now().microsecondsSinceEpoch;
  return templateSummaryFormat.copyWith(
    id: 'custom-$timestamp',
    name: 'カスタム$suffix',
    rules: [
      for (
        var index = 0;
        index < templateSummaryFormat.rules.length;
        index += 1
      )
        templateSummaryFormat.rules[index].copyWith(
          id: 'rule-$timestamp-$index',
        ),
    ],
  );
}

const _appPlatformChannel = MethodChannel('splitlog_x/app');
const _desktopScrollbarGutter = 10.0;
const _compactScrollbarThickness = 6.0;

class DesktopSessionView extends StatefulWidget {
  const DesktopSessionView({super.key, this.storage});

  final SessionStorageService? storage;

  @override
  State<DesktopSessionView> createState() => _DesktopSessionViewState();
}

class _DesktopSessionViewState extends State<DesktopSessionView> {
  _PreviewOverlay _overlay = _PreviewOverlay.none;
  bool _isLocked = false;
  bool _isMonochrome = false;
  bool _storageReady = false;
  bool _storageWritable = true;
  late final SessionStorageService _storage;
  late final List<StopwatchController> _stopwatches;
  int _selectedSessionIndex = 0;
  late DateTime _clock;
  Timer? _ticker;
  Timer? _toastTimer;
  final TextEditingController _lapLabelController = TextEditingController();
  final FocusNode _lapLabelFocus = FocusNode();
  final ScrollController _lapLabelScrollController = ScrollController();
  String? _editingLapId;
  final TextEditingController _sessionTitleController = TextEditingController();
  final FocusNode _sessionTitleFocus = FocusNode();
  bool _isEditingSessionTitle = false;
  final TextEditingController _memoLabelController = TextEditingController();
  final TextEditingController _memoTextController = TextEditingController();
  final TextEditingController _summaryTextController = TextEditingController();
  String? _toastMessage;
  _ToastStyle _toastStyle = _ToastStyle.success;
  int _lapListScrollToken = 0;
  String? _memoLapId;
  String _memoElapsedText = '00:00:00';
  int _ringHoursPerCycle = defaultRingHoursPerCycle;
  SplitAccumulationMode _defaultSplitMode = SplitAccumulationMode.radio;
  String _selectedSummaryFormatId = defaultSummaryFormatId;
  List<SummaryFormatDefinition> _customSummaryFormats = [];
  _SummaryTimeFormat _summaryTimeFormat = _SummaryTimeFormat.decimalHours;
  bool _shortcutsEnabled = true;

  StopwatchController get _stopwatch => _stopwatches[_selectedSessionIndex];

  @override
  void initState() {
    super.initState();
    _storage = widget.storage ?? SessionStorageService();
    _clock = DateTime.now();
    _stopwatches = [
      StopwatchController(
        initialSnapshot: _emptySessionSnapshot(
          _clock,
          _dateTitle(_clock),
          splitMode: _defaultSplitMode,
        ),
      ),
    ];
    _lapLabelFocus.addListener(_handleLapLabelFocusChange);
    _sessionTitleFocus.addListener(_handleSessionTitleFocusChange);
    _appPlatformChannel.setMethodCallHandler(_handlePlatformCall);
    unawaited(_setNativeShortcutsEnabled(_shortcutsEnabled));
    unawaited(_setNativePopoverLocked(_isLocked));
    unawaited(_loadPersistedState());
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_stopwatch.state == SessionState.running && mounted) {
        setState(() {
          _clock = DateTime.now();
        });
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _toastTimer?.cancel();
    _lapLabelFocus.removeListener(_handleLapLabelFocusChange);
    _sessionTitleFocus.removeListener(_handleSessionTitleFocusChange);
    _lapLabelController.dispose();
    _lapLabelFocus.dispose();
    _lapLabelScrollController.dispose();
    _sessionTitleController.dispose();
    _sessionTitleFocus.dispose();
    _memoLabelController.dispose();
    _memoTextController.dispose();
    _summaryTextController.dispose();
    _appPlatformChannel.setMethodCallHandler(null);
    super.dispose();
  }

  int get _totalSeconds => _stopwatch.elapsedSessionSeconds(at: _clock);

  List<String> get _sessionTitles {
    return [
      for (final stopwatch in _stopwatches)
        stopwatch.session?.title ?? _dateTitle(_clock),
    ];
  }

  String get _primaryActionLabel {
    return _stopwatch.state == SessionState.running
        ? '停止'
        : _stopwatch.laps.isEmpty
        ? '開始'
        : '再開';
  }

  String get _sessionStateLabel {
    return switch (_stopwatch.state) {
      SessionState.running => 'Running',
      SessionState.paused => 'Paused',
      SessionState.idle => 'Idle',
      SessionState.stopped || SessionState.finished => 'Stopped',
    };
  }

  Future<void> _loadPersistedState() async {
    try {
      final snapshot = await _storage.load();
      if (!mounted) {
        return;
      }
      if (snapshot != null && snapshot.sessions.isNotEmpty) {
        if (_isPreviewSeedSnapshot(snapshot)) {
          await _storage.delete();
          if (!mounted) {
            return;
          }
        } else {
          var repairedIdentifiers = false;
          setState(() {
            repairedIdentifiers = _restoreStorageSnapshot(snapshot);
          });
          if (repairedIdentifiers) {
            await _storage.save(_storageSnapshot());
          }
          return;
        }
      }

      final hasLegacySnapshot = await _storage.legacySnapshotExists();
      if (!mounted || !hasLegacySnapshot) {
        return;
      }
      setState(() {
        _overlay = _PreviewOverlay.legacyImport;
      });
    } on SessionStorageReadException {
      _storageWritable = false;
      if (mounted) {
        _showToast(
          '保存データを読み込めないため、sessions.jsonへの保存を停止しました',
          style: _ToastStyle.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _storageReady = true;
        });
      }
    }
  }

  bool _isPreviewSeedSnapshot(SplitLogStorageSnapshot snapshot) {
    final sessionIds = [
      for (final session in snapshot.sessions) session.session?.id,
    ];
    return sessionIds.length == 3 &&
        sessionIds[0] == 'session-preview' &&
        sessionIds[1] == 'session-2026/6/26' &&
        sessionIds[2] == 'session-2026/6/24';
  }

  bool _restoreStorageSnapshot(SplitLogStorageSnapshot snapshot) {
    final restored = [
      for (final session in snapshot.sessions)
        StopwatchController(initialSnapshot: session),
    ];
    if (restored.isEmpty) {
      return false;
    }

    _stopwatches
      ..clear()
      ..addAll(restored);
    _selectedSessionIndex = math.min(
      math.max(0, snapshot.selectedSessionIndex),
      _stopwatches.length - 1,
    );
    _clock = DateTime.now();
    _isLocked = snapshot.settings.isLocked;
    _isMonochrome = snapshot.settings.isMonochrome;
    _ringHoursPerCycle = snapshot.settings.ringHoursPerCycle.clamp(1, 24);
    _defaultSplitMode = snapshot.settings.defaultSplitMode;
    _customSummaryFormats = List.of(snapshot.settings.customSummaryFormats);
    _selectedSummaryFormatId = resolveSummaryFormat(
      snapshot.settings.selectedSummaryFormatId,
      _customSummaryFormats,
    ).id;
    _summaryTimeFormat = _summaryTimeFormatFromName(
      snapshot.settings.summaryTimeFormat,
    );
    _shortcutsEnabled = snapshot.settings.shortcutsEnabled;
    unawaited(_setNativeShortcutsEnabled(_shortcutsEnabled));
    unawaited(_setNativePopoverLocked(_isLocked));
    _overlay = _PreviewOverlay.none;
    return restored.any((stopwatch) => stopwatch.repairedIdentifiers);
  }

  SplitLogStorageSnapshot _storageSnapshot() {
    return SplitLogStorageSnapshot(
      savedAt: DateTime.now(),
      sessions: [for (final stopwatch in _stopwatches) stopwatch.snapshot()],
      selectedSessionIndex: _selectedSessionIndex,
      settings: SplitLogSettingsSnapshot(
        isLocked: _isLocked,
        isMonochrome: _isMonochrome,
        ringHoursPerCycle: _ringHoursPerCycle,
        defaultSplitMode: _defaultSplitMode,
        selectedSummaryFormatId: _selectedSummaryFormatId,
        customSummaryFormats: _customSummaryFormats,
        summaryTimeFormat: _summaryTimeFormat.name,
        shortcutsEnabled: _shortcutsEnabled,
      ),
    );
  }

  void _persistState() {
    if (!_storageReady || !_storageWritable) {
      return;
    }
    final snapshot = _storageSnapshot();
    unawaited(_saveSnapshotWithFeedback(snapshot));
  }

  Future<void> _saveSnapshotWithFeedback(
    SplitLogStorageSnapshot snapshot,
  ) async {
    try {
      await _storage.save(snapshot);
    } on Object {
      if (mounted) {
        _showToast('データの保存に失敗しました', style: _ToastStyle.error);
      }
    }
  }

  void _refresh({bool persist = false, bool scrollToSelectedLap = false}) {
    setState(() {
      _clock = DateTime.now();
      if (scrollToSelectedLap) {
        _lapListScrollToken += 1;
      }
    });
    if (persist) {
      _persistState();
    }
  }

  void _handleLapLabelFocusChange() {
    if (!mounted || _lapLabelFocus.hasFocus || _editingLapId == null) {
      return;
    }
    _commitLapLabelEdit();
  }

  void _handleSessionTitleFocusChange() {
    if (!mounted || _sessionTitleFocus.hasFocus || !_isEditingSessionTitle) {
      return;
    }
    _commitSessionTitleEdit();
  }

  void _commitActiveEdits() {
    if (_editingLapId != null) {
      _commitLapLabelEdit();
    }
    if (_isEditingSessionTitle) {
      _commitSessionTitleEdit();
    }
  }

  void _commitActiveMemoEditIfNeeded() {
    final lapId = _memoLapId;
    if (lapId == null) {
      return;
    }
    _stopwatch.updateLapLabel(lapId, _memoLabelController.text);
    _stopwatch.updateLapMemo(lapId, _memoTextController.text);
    _memoLapId = null;
    _memoLabelController.clear();
    _memoTextController.clear();
  }

  void _setSplitMode(SplitAccumulationMode mode) {
    _stopwatch.setSplitAccumulationMode(mode, at: DateTime.now());
    _refresh(persist: true);
  }

  void _togglePrimaryAction() {
    final now = DateTime.now();
    if (_stopwatch.state == SessionState.running) {
      _stopwatch.finishSession(at: now);
    } else {
      _stopwatch.startSession(
        defaultSplitAccumulationMode: _stopwatch.splitAccumulationMode,
        at: now,
      );
    }
    _refresh(persist: true);
  }

  void _finishLap() {
    _stopwatch.finishLap(at: DateTime.now());
    _refresh(persist: true);
  }

  void _activateLapFromLeadingControl(String lapId) {
    final now = DateTime.now();
    if (_stopwatch.splitAccumulationMode == SplitAccumulationMode.checkbox) {
      _stopwatch.toggleLapActive(lapId, at: now);
    }
    _stopwatch.selectLap(lapId, at: now);
    _refresh(persist: true);
  }

  void _beginLapLabelEdit(WorkLap lap) {
    _commitActiveEdits();
    setState(() {
      _editingLapId = lap.id;
      _lapLabelController.text = _singleLineLabel(lap.label);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _editingLapId != lap.id) {
        return;
      }
      _lapLabelFocus.requestFocus();
      if (_lapLabelScrollController.hasClients) {
        _lapLabelScrollController.jumpTo(0);
      }
      _lapLabelController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _lapLabelController.text.length,
      );
    });
  }

  void _commitLapLabelEdit() {
    final lapId = _editingLapId;
    if (lapId == null) {
      return;
    }
    _stopwatch.updateLapLabel(lapId, _lapLabelController.text);
    setState(() {
      _editingLapId = null;
      _lapLabelController.clear();
      _clock = DateTime.now();
    });
    _persistState();
  }

  void _beginLapMemoEdit(WorkLap lap) {
    _commitActiveEdits();
    final lapSeconds = _stopwatch.displayedLapSecondsMap(at: DateTime.now());
    setState(() {
      _memoLapId = lap.id;
      _memoLabelController.text = _singleLineLabel(lap.label);
      _memoTextController.text = lap.memo;
      _memoElapsedText = _formatDuration(
        lapSeconds[lap.id] ?? lap.accumulatedSeconds,
      );
      _overlay = _PreviewOverlay.memo;
    });
  }

  void _closeMemo() {
    setState(() {
      _commitActiveMemoEditIfNeeded();
      _clock = DateTime.now();
      _overlay = _PreviewOverlay.none;
    });
    _persistState();
  }

  _SessionSummary _currentSessionSummary({
    required DateTime at,
    SummaryFormatDefinition? format,
    _SummaryTimeFormat? timeFormat,
  }) {
    return _buildSessionSummary(
      stopwatch: _stopwatch,
      lapSeconds: _stopwatch.displayedLapSecondsMap(at: at),
      totalSeconds: _stopwatch.elapsedSessionSeconds(at: at),
      format: format ?? _selectedSummaryFormat,
      timeFormat: timeFormat ?? _summaryTimeFormat,
    );
  }

  SummaryFormatDefinition get _selectedSummaryFormat {
    return resolveSummaryFormat(
      _selectedSummaryFormatId,
      _customSummaryFormats,
    );
  }

  void _replaceSummaryDraft(String text) {
    _summaryTextController.value = TextEditingValue(
      text: text,
      selection: const TextSelection.collapsed(offset: 0),
    );
  }

  void _showSummary() {
    _commitActiveEdits();
    final now = DateTime.now();
    _replaceSummaryDraft(_currentSessionSummary(at: now).text);
    setState(() {
      _clock = now;
      _overlay = _PreviewOverlay.summary;
    });
    _persistState();
  }

  Future<void> _copySummary() async {
    try {
      final copyOperation = Clipboard.setData(
        ClipboardData(text: _summaryTextController.text),
      );
      if (mounted) {
        _showToast('サマリーをコピーしました');
      }
      await copyOperation;
    } catch (_) {
      if (mounted) {
        _showToast('サマリーのコピーに失敗しました。', style: _ToastStyle.error);
      }
    }
  }

  void _showToast(String message, {_ToastStyle style = _ToastStyle.success}) {
    _toastTimer?.cancel();
    setState(() {
      _toastMessage = message;
      _toastStyle = style;
    });
    _toastTimer = Timer(const Duration(milliseconds: 1800), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _toastMessage = null;
      });
    });
  }

  void _beginSessionTitleEdit() {
    _commitActiveEdits();
    setState(() {
      _isEditingSessionTitle = true;
      _sessionTitleController.text =
          _stopwatch.session?.title ?? _dateTitle(_clock);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isEditingSessionTitle) {
        return;
      }
      _sessionTitleFocus.requestFocus();
      _sessionTitleController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _sessionTitleController.text.length,
      );
    });
  }

  void _commitSessionTitleEdit() {
    if (!_isEditingSessionTitle) {
      return;
    }
    _stopwatch.updateSessionTitle(_sessionTitleController.text);
    setState(() {
      _isEditingSessionTitle = false;
      _sessionTitleController.clear();
      _clock = DateTime.now();
    });
    _persistState();
  }

  void _selectSession(int index) {
    if (!_stopwatches.asMap().containsKey(index) ||
        index == _selectedSessionIndex) {
      return;
    }
    _commitActiveEdits();
    final now = DateTime.now();
    if (_stopwatch.state == SessionState.running) {
      _stopwatch.finishSession(at: now);
    }
    setState(() {
      _selectedSessionIndex = index;
      _clock = now;
      _overlay = _PreviewOverlay.none;
    });
    _persistState();
  }

  void _resetSession() {
    _stopwatch.reset(at: DateTime.now());
    _hideOverlay();
    _persistState();
  }

  void _deleteSession() {
    final now = DateTime.now();
    setState(() {
      if (_stopwatches.length <= 1) {
        _stopwatch.reset(at: now);
      } else {
        _stopwatches.removeAt(_selectedSessionIndex);
        _selectedSessionIndex = math.max(0, _selectedSessionIndex - 1);
      }
      _clock = now;
      _overlay = _PreviewOverlay.none;
    });
    _persistState();
  }

  void _deleteAllSessionData({bool showFeedback = true}) {
    final now = DateTime.now();
    setState(() {
      _stopwatches
        ..clear()
        ..add(
          StopwatchController(
            initialSnapshot: _emptySessionSnapshot(
              now,
              _dateTitle(now),
              splitMode: _defaultSplitMode,
            ),
          ),
        );
      _selectedSessionIndex = 0;
      _clock = now;
    });
    _persistState();
    if (showFeedback) {
      _showToast('セッション情報を削除しました');
    }
  }

  void _deleteAllLapData({bool showFeedback = true}) {
    final now = DateTime.now();
    setState(() {
      for (final stopwatch in _stopwatches) {
        stopwatch.reset(at: now);
      }
      _clock = now;
    });
    _persistState();
    if (showFeedback) {
      _showToast('Split情報を削除しました');
    }
  }

  void _resetSettings({bool showFeedback = true}) {
    setState(() {
      _isMonochrome = false;
      _ringHoursPerCycle = defaultRingHoursPerCycle;
      _defaultSplitMode = SplitAccumulationMode.radio;
      _selectedSummaryFormatId = defaultSummaryFormatId;
      _customSummaryFormats = [];
      _summaryTimeFormat = _SummaryTimeFormat.decimalHours;
      _shortcutsEnabled = true;
    });
    _persistState();
    unawaited(_setNativeShortcutsEnabled(_shortcutsEnabled));
    if (showFeedback) {
      _showToast('設定を初期化しました');
    }
  }

  void _initializeAllData() {
    _storageWritable = true;
    _deleteAllSessionData(showFeedback: false);
    _resetSettings(showFeedback: false);
    _showToast('全データを初期化しました');
  }

  void _addSession() {
    final now = DateTime.now();
    _commitActiveEdits();
    if (_stopwatch.state == SessionState.running) {
      _stopwatch.finishSession(at: now);
    }
    setState(() {
      _stopwatches.insert(
        0,
        StopwatchController(
          initialSnapshot: _emptySessionSnapshot(
            now,
            _nextSessionTitle(now, _sessionTitles),
            splitMode: _defaultSplitMode,
          ),
        ),
      );
      _selectedSessionIndex = 0;
      _clock = now;
    });
    _persistState();
  }

  void _show(_PreviewOverlay overlay) {
    _commitActiveEdits();
    setState(() {
      _overlay = overlay;
    });
    _persistState();
  }

  void _hideOverlay() {
    _commitActiveEdits();
    _commitActiveMemoEditIfNeeded();
    setState(() {
      _overlay = _PreviewOverlay.none;
    });
    _persistState();
  }

  void _setRingHoursPerCycle(int value) {
    setState(() {
      _ringHoursPerCycle = value.clamp(1, 24);
    });
    _persistState();
  }

  void _setDefaultSplitMode(SplitAccumulationMode mode) {
    setState(() {
      _defaultSplitMode = mode;
    });
    _persistState();
  }

  void _setSummaryFormat(String formatId) {
    final resolved = resolveSummaryFormat(formatId, _customSummaryFormats);
    setState(() {
      _selectedSummaryFormatId = resolved.id;
    });
    _persistState();
  }

  void _setSummaryFormatFromSummary(String formatId) {
    final format = resolveSummaryFormat(formatId, _customSummaryFormats);
    final now = DateTime.now();
    final summary = _currentSessionSummary(at: now, format: format);
    setState(() {
      _selectedSummaryFormatId = format.id;
      _clock = now;
    });
    _replaceSummaryDraft(summary.text);
    _persistState();
  }

  void _saveCustomSummaryFormat(SummaryFormatDefinition format) {
    setState(() {
      _customSummaryFormats = _upsertCustomSummaryFormat(
        _customSummaryFormats,
        format,
      );
      _selectedSummaryFormatId = format.id;
    });
    _persistState();
  }

  void _saveCustomSummaryFormatFromSummary(SummaryFormatDefinition format) {
    final now = DateTime.now();
    final summary = _currentSessionSummary(at: now, format: format);
    setState(() {
      _customSummaryFormats = _upsertCustomSummaryFormat(
        _customSummaryFormats,
        format,
      );
      _selectedSummaryFormatId = format.id;
      _clock = now;
    });
    _replaceSummaryDraft(summary.text);
    _persistState();
  }

  void _deleteCustomSummaryFormat(String formatId) {
    setState(() {
      _customSummaryFormats = [
        for (final format in _customSummaryFormats)
          if (format.id != formatId) format,
      ];
      if (_selectedSummaryFormatId == formatId) {
        _selectedSummaryFormatId = defaultSummaryFormatId;
      }
    });
    _persistState();
  }

  void _setSummaryTimeFormat(_SummaryTimeFormat format) {
    setState(() {
      _summaryTimeFormat = format;
    });
    _persistState();
  }

  void _setSummaryTimeFormatFromSummary(_SummaryTimeFormat format) {
    final now = DateTime.now();
    final summary = _currentSessionSummary(at: now, timeFormat: format);
    setState(() {
      _summaryTimeFormat = format;
      _clock = now;
    });
    _replaceSummaryDraft(summary.text);
    _persistState();
  }

  void _setShortcutsEnabled(bool enabled) {
    setState(() {
      _shortcutsEnabled = enabled;
    });
    _persistState();
    unawaited(_setNativeShortcutsEnabled(enabled));
  }

  void _toggleLock() {
    setState(() {
      _isLocked = !_isLocked;
    });
    _persistState();
    unawaited(_setNativePopoverLocked(_isLocked));
  }

  void _setTheme(bool isMonochrome) {
    setState(() {
      _isMonochrome = isMonochrome;
    });
    _persistState();
  }

  Future<void> _importLegacyData() async {
    try {
      final snapshot = await _storage.importLegacySnapshot();
      if (!mounted) {
        return;
      }
      if (snapshot == null || snapshot.sessions.isEmpty) {
        setState(() {
          _overlay = _PreviewOverlay.legacyImportMissing;
        });
        return;
      }

      setState(() {
        _storageWritable = true;
        _restoreStorageSnapshot(snapshot);
      });
      _persistState();
      _showToast('旧データをインポートしました');
    } on Object {
      if (mounted) {
        _showToast('旧データの読み込みに失敗しました', style: _ToastStyle.error);
      }
    }
  }

  Future<void> _importLegacyDataFromFile() async {
    try {
      final content = await _appPlatformChannel.invokeMethod<String>(
        'chooseLegacyFile',
      );
      if (!mounted || content == null) {
        return;
      }

      final snapshot = await _storage.importLegacySnapshotFromContent(content);
      if (!mounted) {
        return;
      }
      if (snapshot == null || snapshot.sessions.isEmpty) {
        setState(() {
          _overlay = _PreviewOverlay.legacyImportMissing;
        });
        return;
      }

      setState(() {
        _storageWritable = true;
        _restoreStorageSnapshot(snapshot);
      });
      _persistState();
      _showToast('旧データをインポートしました');
    } on Object {
      if (mounted) {
        _showToast('sessions.jsonの読み込みに失敗しました', style: _ToastStyle.error);
      }
    }
  }

  Future<void> _openContactMail() async {
    try {
      await _appPlatformChannel.invokeMethod<void>('openContact');
    } on Object {
      if (mounted) {
        _showToast('メールアプリを開けませんでした', style: _ToastStyle.error);
      }
    }
  }

  Future<void> _quitApp() async {
    if (!await _prepareToQuit()) {
      return;
    }
    await _appPlatformChannel.invokeMethod<void>('quitApp');
  }

  Future<bool> _prepareToQuit() async {
    try {
      if (_storageReady && _storageWritable) {
        _commitActiveEdits();
        _commitActiveMemoEditIfNeeded();
        await _storage.save(_storageSnapshot());
      }
      await _storage.flush();
      return true;
    } on Object {
      if (mounted) {
        _showToast('データを保存できなかったため終了を中止しました', style: _ToastStyle.error);
      }
      return false;
    }
  }

  Future<void> _setNativeShortcutsEnabled(bool enabled) async {
    try {
      await _appPlatformChannel.invokeMethod<void>('setShortcutsEnabled', {
        'enabled': enabled,
      });
    } on MissingPluginException {
      // Platforms without desktop integration ignore global shortcuts.
    }
  }

  Future<void> _setNativePopoverLocked(bool locked) async {
    try {
      await _appPlatformChannel.invokeMethod<void>('setPopoverLocked', {
        'locked': locked,
      });
    } on MissingPluginException {
      // Platforms without desktop integration ignore popover locking.
    }
  }

  Future<Object?> _handlePlatformCall(MethodCall call) async {
    if (call.method == 'prepareToQuit') {
      return _prepareToQuit();
    }
    if (call.method != 'shortcutAction') {
      return null;
    }
    final arguments = call.arguments;
    if (arguments is! Map<Object?, Object?>) {
      return null;
    }
    _handleShortcutAction(arguments);
    return null;
  }

  void _handleShortcutAction(Map<Object?, Object?> arguments) {
    if (!_storageReady || !_shortcutsEnabled || !mounted) {
      return;
    }
    final action = arguments['action'] as String?;
    final now = DateTime.now();
    var handled = false;
    var shouldScrollToSelectedLap = false;

    switch (action) {
      case 'split':
        if (_stopwatch.state == SessionState.running) {
          _stopwatch.finishLap(at: now);
          handled = true;
        }
      case 'stop':
        if (_stopwatch.state == SessionState.running ||
            _stopwatch.state == SessionState.paused) {
          _stopwatch.finishSession(at: now);
          handled = true;
        }
      case 'resume':
        if (_stopwatch.state == SessionState.paused ||
            _stopwatch.state == SessionState.stopped) {
          _stopwatch.resumeSession(at: now);
          handled = true;
        } else if (_stopwatch.state == SessionState.idle) {
          _stopwatch.startSession(
            defaultSplitAccumulationMode: _stopwatch.splitAccumulationMode,
            at: now,
          );
          handled = true;
        }
      case 'memo':
        final currentLap = _stopwatch.currentLap;
        if (currentLap != null) {
          _beginLapMemoEdit(currentLap);
          handled = true;
        }
      case 'targetLap':
        final index = arguments['index'];
        if (index is int) {
          handled = _stopwatch.selectOrToggleLapForShortcut(index, at: now);
          shouldScrollToSelectedLap = handled;
        }
      case 'moveLap':
        final offset = arguments['offset'];
        if (offset is int) {
          handled = _stopwatch.moveSelectedLapForShortcut(offset, at: now);
          shouldScrollToSelectedLap = handled;
        }
    }

    if (handled) {
      _refresh(persist: true, scrollToSelectedLap: shouldScrollToSelectedLap);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = _DesktopPreviewColors(isMonochrome: _isMonochrome);
    final lapSeconds = _stopwatch.displayedLapSecondsMap(at: _clock);
    final summary = _buildSessionSummary(
      stopwatch: _stopwatch,
      lapSeconds: lapSeconds,
      totalSeconds: _totalSeconds,
      format: _selectedSummaryFormat,
      timeFormat: _summaryTimeFormat,
    );

    return SizedBox(
      width: 540,
      height: 380,
      child: Material(
        color: colors.surface,
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: IgnorePointer(
          ignoring: !_storageReady,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _HeaderBar(
                      colors: colors,
                      sessions: _sessionTitles,
                      selectedSessionIndex: _selectedSessionIndex,
                      isLocked: _isLocked,
                      onHelp: () => _show(_PreviewOverlay.help),
                      onToggleLock: _toggleLock,
                      onSessionList: () => _show(_PreviewOverlay.sessionList),
                      onSelectSession: _selectSession,
                      onAddSession: _addSession,
                      onSettings: () => _show(_PreviewOverlay.settings),
                    ),
                    const SizedBox(height: 4),
                    Divider(height: 1, color: colors.border),
                    const SizedBox(height: 8),
                    _SessionStatusRow(
                      colors: colors,
                      sessionTitle:
                          _stopwatch.session?.title ?? _dateTitle(_clock),
                      isEditingSessionTitle: _isEditingSessionTitle,
                      sessionTitleController: _sessionTitleController,
                      sessionTitleFocus: _sessionTitleFocus,
                      splitMode: _stopwatch.splitAccumulationMode,
                      totalElapsed: _formatDuration(_totalSeconds),
                      onBeginSessionTitleEdit: _beginSessionTitleEdit,
                      onCommitSessionTitleEdit: _commitSessionTitleEdit,
                      onToggleSplitMode: _setSplitMode,
                      onSummary: _showSummary,
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _TimelineCard(
                            colors: colors,
                            laps: _stopwatch.laps,
                            lapSeconds: lapSeconds,
                            totalSeconds: _totalSeconds,
                            ringHoursPerCycle: _ringHoursPerCycle,
                            onCycleTap: () => _show(_PreviewOverlay.settings),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _LapList(
                              colors: colors,
                              laps: _stopwatch.laps,
                              lapSeconds: lapSeconds,
                              splitMode: _stopwatch.splitAccumulationMode,
                              selectedLapId: _stopwatch.selectedLapId,
                              activeLapIds: _stopwatch.activeLapIds,
                              editingLapId: _editingLapId,
                              editingLabelController: _lapLabelController,
                              editingLabelFocus: _lapLabelFocus,
                              editingLabelScrollController:
                                  _lapLabelScrollController,
                              stateLabel: _sessionStateLabel,
                              scrollToSelectionToken: _lapListScrollToken,
                              onMemo: _beginLapMemoEdit,
                              onBeginLapLabelEdit: _beginLapLabelEdit,
                              onCommitLapLabelEdit: _commitLapLabelEdit,
                              onLeadingControl: _activateLapFromLeadingControl,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    _BottomActionRow(
                      colors: colors,
                      primaryLabel: _primaryActionLabel,
                      splitEnabled: _stopwatch.state == SessionState.running,
                      onPrimary: _togglePrimaryAction,
                      onSplit: _finishLap,
                      onReset: () => _show(_PreviewOverlay.resetConfirmation),
                      onDelete: () => _show(_PreviewOverlay.deleteConfirmation),
                    ),
                  ],
                ),
              ),
              _OverlayLayer(
                overlay: _overlay,
                colors: colors,
                sessions: _sessionTitles,
                selectedSessionIndex: _selectedSessionIndex,
                isMonochrome: _isMonochrome,
                ringHoursPerCycle: _ringHoursPerCycle,
                defaultSplitMode: _defaultSplitMode,
                selectedSummaryFormatId: _selectedSummaryFormatId,
                customSummaryFormats: _customSummaryFormats,
                summaryTimeFormat: _summaryTimeFormat,
                summary: summary,
                summaryTimePreviewLabel: summary.timeFormatLabel,
                shortcutsEnabled: _shortcutsEnabled,
                memoLabelController: _memoLabelController,
                memoTextController: _memoTextController,
                summaryTextController: _summaryTextController,
                memoElapsedText: _memoElapsedText,
                onClose: _hideOverlay,
                onCloseMemo: _closeMemo,
                onOpenGuide: () => _show(_PreviewOverlay.guide),
                onOpenContact: () => _show(_PreviewOverlay.contact),
                onOpenContactMail: () => unawaited(_openContactMail()),
                onReset: _resetSession,
                onDelete: _deleteSession,
                onSelectSession: _selectSession,
                onSetTheme: _setTheme,
                onSetRingHoursPerCycle: _setRingHoursPerCycle,
                onSetDefaultSplitMode: _setDefaultSplitMode,
                onSetSummaryFormat: _setSummaryFormat,
                onSaveCustomSummaryFormat: _saveCustomSummaryFormat,
                onSaveCustomSummaryFormatFromSummary:
                    _saveCustomSummaryFormatFromSummary,
                onDeleteCustomSummaryFormat: _deleteCustomSummaryFormat,
                onSetSummaryTimeFormat: _setSummaryTimeFormat,
                onSetSummaryFormatFromSummary: _setSummaryFormatFromSummary,
                onSetSummaryTimeFormatFromSummary:
                    _setSummaryTimeFormatFromSummary,
                onCopySummary: () => unawaited(_copySummary()),
                onSetShortcutsEnabled: _setShortcutsEnabled,
                onRequestLegacyImport: () =>
                    _show(_PreviewOverlay.legacyImport),
                onImportLegacyData: () => unawaited(_importLegacyData()),
                onImportLegacyDataFromFile: () =>
                    unawaited(_importLegacyDataFromFile()),
                onQuitApp: () => unawaited(_quitApp()),
                onDeleteSessionData: () => _deleteAllSessionData(),
                onDeleteLapData: () => _deleteAllLapData(),
                onResetSettings: () => _resetSettings(),
                onInitializeAllData: _initializeAllData,
              ),
              if (_toastMessage != null)
                Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: _ToastBanner(
                        message: _toastMessage!,
                        style: _toastStyle,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderBar extends StatelessWidget {
  const _HeaderBar({
    required this.colors,
    required this.sessions,
    required this.selectedSessionIndex,
    required this.isLocked,
    required this.onHelp,
    required this.onToggleLock,
    required this.onSessionList,
    required this.onSelectSession,
    required this.onAddSession,
    required this.onSettings,
  });

  final _DesktopPreviewColors colors;
  final List<String> sessions;
  final int selectedSessionIndex;
  final bool isLocked;
  final VoidCallback onHelp;
  final VoidCallback onToggleLock;
  final VoidCallback onSessionList;
  final ValueChanged<int> onSelectSession;
  final VoidCallback onAddSession;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          const Icon(Icons.timer_outlined, size: 16),
          const SizedBox(width: 5),
          const Text(
            'SplitLog',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          _CircleIconButton(
            icon: Icons.question_mark,
            tooltip: '使い方',
            colors: colors,
            size: 16,
            iconSize: 9,
            onPressed: onHelp,
          ),
          const SizedBox(width: 4),
          _CircleIconButton(
            icon: isLocked ? Icons.lock : Icons.lock_open,
            tooltip: isLocked ? 'Popoverロック中' : 'Popoverロック',
            colors: colors,
            size: 16,
            iconSize: 9,
            filled: isLocked,
            onPressed: onToggleLock,
          ),
          const Spacer(),
          _SessionSelector(
            colors: colors,
            sessions: sessions,
            selectedIndex: selectedSessionIndex,
            onSelect: onSelectSession,
            onOverflow: onSessionList,
          ),
          const SizedBox(width: 8),
          _CircleIconButton(
            icon: Icons.add,
            tooltip: 'セッション追加',
            colors: colors,
            size: 24,
            iconSize: 12,
            onPressed: onAddSession,
          ),
          const SizedBox(width: 8),
          _CircleIconButton(
            icon: Icons.settings_outlined,
            tooltip: '設定',
            colors: colors,
            size: 24,
            iconSize: 12,
            onPressed: onSettings,
          ),
        ],
      ),
    );
  }
}

class _SessionSelector extends StatefulWidget {
  const _SessionSelector({
    required this.colors,
    required this.sessions,
    required this.selectedIndex,
    required this.onSelect,
    required this.onOverflow,
  });

  final _DesktopPreviewColors colors;
  final List<String> sessions;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onOverflow;

  @override
  State<_SessionSelector> createState() => _SessionSelectorState();
}

class _SessionSelectorState extends State<_SessionSelector> {
  static const double _itemWidth = 74;
  static const double _itemSpacing = 4;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scheduleSelectedSessionScroll(animated: false);
  }

  @override
  void didUpdateWidget(covariant _SessionSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sessionCountChanged =
        oldWidget.sessions.length != widget.sessions.length;
    final selectionChanged = oldWidget.selectedIndex != widget.selectedIndex;
    if (sessionCountChanged || selectionChanged) {
      _scheduleSelectedSessionScroll(
        animated: selectionChanged && !sessionCountChanged,
      );
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scheduleSelectedSessionScroll({required bool animated}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _scrollToSelectedSession(animated: animated);
      }
    });
  }

  void _scrollToSelectedSession({required bool animated}) {
    if (!_scrollController.hasClients || widget.sessions.isEmpty) {
      return;
    }

    final position = _scrollController.position;
    final selectedIndex = widget.selectedIndex.clamp(
      0,
      widget.sessions.length - 1,
    );
    final selectedCenter =
        selectedIndex * (_itemWidth + _itemSpacing) + (_itemWidth / 2);
    final targetOffset = (selectedCenter - position.viewportDimension / 2)
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();

    if ((position.pixels - targetOffset).abs() < 0.5) {
      return;
    }
    if (animated) {
      _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
      );
    } else {
      _scrollController.jumpTo(targetOffset);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final sessions = widget.sessions;
    final selectedIndex = widget.selectedIndex;
    final onSelect = widget.onSelect;
    final onOverflow = widget.onOverflow;

    return Container(
      height: 22,
      decoration: BoxDecoration(
        border: Border.all(color: colors.strongBorder),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 220,
            child: ListView.separated(
              key: const ValueKey<String>('session-selector-scroll-view'),
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount: sessions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 4),
              itemBuilder: (context, index) {
                final session = sessions[index];
                final isSelected = index == selectedIndex;
                return InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => onSelect(index),
                  child: Container(
                    key: ValueKey<String>('session-selector-chip-$index'),
                    width: 74,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? colors.selectedChip
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      session,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 22,
            child: Tooltip(
              message: 'セッション一覧',
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: onOverflow,
                child: Center(
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: colors.overflowButtonBackground,
                      shape: BoxShape.circle,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _Dot(color: colors.primaryText),
                        const SizedBox(height: 2),
                        _Dot(color: colors.primaryText),
                        const SizedBox(height: 2),
                        _Dot(color: colors.primaryText),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionStatusRow extends StatelessWidget {
  const _SessionStatusRow({
    required this.colors,
    required this.sessionTitle,
    required this.isEditingSessionTitle,
    required this.sessionTitleController,
    required this.sessionTitleFocus,
    required this.splitMode,
    required this.totalElapsed,
    required this.onBeginSessionTitleEdit,
    required this.onCommitSessionTitleEdit,
    required this.onToggleSplitMode,
    required this.onSummary,
  });

  final _DesktopPreviewColors colors;
  final String sessionTitle;
  final bool isEditingSessionTitle;
  final TextEditingController sessionTitleController;
  final FocusNode sessionTitleFocus;
  final SplitAccumulationMode splitMode;
  final String totalElapsed;
  final VoidCallback onBeginSessionTitleEdit;
  final VoidCallback onCommitSessionTitleEdit;
  final ValueChanged<SplitAccumulationMode> onToggleSplitMode;
  final VoidCallback onSummary;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          SizedBox(
            width: 238,
            height: 28,
            child: _SessionTitleUnderline(
              title: sessionTitle,
              colors: colors,
              isEditing: isEditingSessionTitle,
              controller: sessionTitleController,
              focusNode: sessionTitleFocus,
              onBeginEdit: onBeginSessionTitleEdit,
              onCommitEdit: onCommitSessionTitleEdit,
            ),
          ),
          const Spacer(),
          _SplitModeControl(
            colors: colors,
            splitMode: splitMode,
            onChanged: onToggleSplitMode,
          ),
          const SizedBox(width: 6),
          _CircleIconButton(
            icon: Icons.description_outlined,
            tooltip: 'サマリー',
            colors: colors,
            size: 22,
            iconSize: 12,
            onPressed: onSummary,
          ),
          const SizedBox(width: 6),
          Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: colors.section,
              border: Border.all(color: colors.border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Text(
                  '全体経過',
                  style: TextStyle(fontSize: 13, color: colors.secondaryText),
                ),
                const SizedBox(width: 5),
                Text(
                  totalElapsed,
                  style: const TextStyle(
                    fontSize: 13,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SplitModeControl extends StatelessWidget {
  const _SplitModeControl({
    required this.colors,
    required this.splitMode,
    required this.onChanged,
  });

  final _DesktopPreviewColors colors;
  final SplitAccumulationMode splitMode;
  final ValueChanged<SplitAccumulationMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 26,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colors.section,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          _modeButton(Icons.radio_button_checked, SplitAccumulationMode.radio),
          _modeButton(Icons.check_box, SplitAccumulationMode.checkbox),
        ],
      ),
    );
  }

  Widget _modeButton(IconData icon, SplitAccumulationMode mode) {
    final selected = splitMode == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => onChanged(mode),
      child: Container(
        width: 24,
        height: 22,
        decoration: BoxDecoration(
          color: selected
              ? colors.accent.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Icon(icon, size: 12, color: colors.primaryText),
      ),
    );
  }
}

class _SessionTitleUnderline extends StatelessWidget {
  const _SessionTitleUnderline({
    required this.title,
    required this.colors,
    required this.isEditing,
    required this.controller,
    required this.focusNode,
    required this.onBeginEdit,
    required this.onCommitEdit,
  });

  final String title;
  final _DesktopPreviewColors colors;
  final bool isEditing;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onBeginEdit;
  final VoidCallback onCommitEdit;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 238),
        child: IntrinsicWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 20,
                child: isEditing
                    ? TextField(
                        controller: controller,
                        focusNode: focusNode,
                        onSubmitted: (_) => onCommitEdit(),
                        maxLines: 1,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: true,
                          fillColor: colors.inlineEditorBackground,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                        ),
                      )
                    : GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onBeginEdit,
                        child: Text(
                          title,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 2),
              Container(height: 1, color: colors.softText),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimelineCard extends StatelessWidget {
  const _TimelineCard({
    required this.colors,
    required this.laps,
    required this.lapSeconds,
    required this.totalSeconds,
    required this.ringHoursPerCycle,
    required this.onCycleTap,
  });

  final _DesktopPreviewColors colors;
  final List<WorkLap> laps;
  final Map<String, int> lapSeconds;
  final int totalSeconds;
  final int ringHoursPerCycle;
  final VoidCallback onCycleTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 214,
      height: 214,
      decoration: BoxDecoration(
        color: colors.section,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        children: [
          Center(
            child: SizedBox(
              width: 198,
              height: 198,
              child: CustomPaint(
                painter: _TimelineRingPainter(
                  colors: colors,
                  laps: laps,
                  lapSeconds: lapSeconds,
                  totalSeconds: totalSeconds,
                  ringHoursPerCycle: ringHoursPerCycle,
                ),
              ),
            ),
          ),
          Positioned(
            left: 8,
            top: 8,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onCycleTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  children: [
                    Icon(Icons.refresh, size: 9, color: colors.secondaryText),
                    const SizedBox(width: 2),
                    Text(
                      '${ringHoursPerCycle}h',
                      style: TextStyle(
                        fontSize: 9,
                        color: colors.secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LapList extends StatefulWidget {
  const _LapList({
    required this.colors,
    required this.laps,
    required this.lapSeconds,
    required this.splitMode,
    required this.selectedLapId,
    required this.activeLapIds,
    required this.editingLapId,
    required this.editingLabelController,
    required this.editingLabelFocus,
    required this.editingLabelScrollController,
    required this.stateLabel,
    required this.scrollToSelectionToken,
    required this.onMemo,
    required this.onBeginLapLabelEdit,
    required this.onCommitLapLabelEdit,
    required this.onLeadingControl,
  });

  final _DesktopPreviewColors colors;
  final List<WorkLap> laps;
  final Map<String, int> lapSeconds;
  final SplitAccumulationMode splitMode;
  final String? selectedLapId;
  final Set<String> activeLapIds;
  final String? editingLapId;
  final TextEditingController editingLabelController;
  final FocusNode editingLabelFocus;
  final ScrollController editingLabelScrollController;
  final String stateLabel;
  final int scrollToSelectionToken;
  final ValueChanged<WorkLap> onMemo;
  final ValueChanged<WorkLap> onBeginLapLabelEdit;
  final VoidCallback onCommitLapLabelEdit;
  final ValueChanged<String> onLeadingControl;

  @override
  State<_LapList> createState() => _LapListState();
}

class _LapListState extends State<_LapList> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  final Map<String, GlobalKey> _rowKeys = {};

  @override
  void didUpdateWidget(covariant _LapList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final currentIds = {for (final lap in widget.laps) lap.id};
    _rowKeys.removeWhere((id, _) => !currentIds.contains(id));

    if (oldWidget.laps.length != widget.laps.length) {
      _scheduleScroll(_scrollToBottom);
    } else if (oldWidget.scrollToSelectionToken !=
        widget.scrollToSelectionToken) {
      _scheduleScroll(_scrollToSelectedLap);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scheduleScroll(VoidCallback action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        action();
      }
    });
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) {
      return;
    }
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _scrollToSelectedLap() {
    if (!_scrollController.hasClients) {
      return;
    }
    final selectedId = widget.selectedLapId;
    final rowContext = selectedId == null
        ? null
        : _rowKeys[selectedId]?.currentContext;
    final viewportContext = _viewportKey.currentContext;
    final rowBox = rowContext?.findRenderObject() as RenderBox?;
    final viewportBox = viewportContext?.findRenderObject() as RenderBox?;
    if (rowBox == null || viewportBox == null) {
      return;
    }

    final rowTop = rowBox.localToGlobal(Offset.zero, ancestor: viewportBox).dy;
    final targetOffset =
        (_scrollController.offset +
                rowTop -
                ((viewportBox.size.height - rowBox.size.height) / 2))
            .clamp(0.0, _scrollController.position.maxScrollExtent)
            .toDouble();
    _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final laps = widget.laps;
    final lapSeconds = widget.lapSeconds;
    final splitMode = widget.splitMode;
    final selectedLapId = widget.selectedLapId;
    final activeLapIds = widget.activeLapIds;
    final editingLapId = widget.editingLapId;

    if (laps.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Splitはまだありません',
            style: TextStyle(fontSize: 13, color: colors.secondaryText),
          ),
          Text(
            '開始して下さい',
            style: TextStyle(color: colors.secondaryText, fontSize: 12),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SingleChildScrollView(
            key: _viewportKey,
            controller: _scrollController,
            child: Column(
              children: [
                for (var index = 0; index < laps.length; index += 1)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: index == laps.length - 1 ? 0 : 6,
                    ),
                    child: _LapRow(
                      key: _rowKeys.putIfAbsent(laps[index].id, GlobalKey.new),
                      colors: colors,
                      lap: laps[index],
                      elapsed: _formatDuration(
                        lapSeconds[laps[index].id] ??
                            laps[index].accumulatedSeconds,
                      ),
                      splitMode: splitMode,
                      selected: selectedLapId == laps[index].id,
                      active: activeLapIds.contains(laps[index].id),
                      isEditing: editingLapId == laps[index].id,
                      editingController: widget.editingLabelController,
                      editingFocus: widget.editingLabelFocus,
                      editingScrollController:
                          widget.editingLabelScrollController,
                      onMemo: () => widget.onMemo(laps[index]),
                      onBeginEdit: () =>
                          widget.onBeginLapLabelEdit(laps[index]),
                      onCommitEdit: widget.onCommitLapLabelEdit,
                      onLeadingControl: () =>
                          widget.onLeadingControl(laps[index].id),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          widget.stateLabel,
          style: TextStyle(fontSize: 12, color: colors.secondaryText),
        ),
      ],
    );
  }
}

class _LapRow extends StatelessWidget {
  const _LapRow({
    super.key,
    required this.colors,
    required this.lap,
    required this.elapsed,
    required this.splitMode,
    required this.selected,
    required this.active,
    required this.isEditing,
    required this.editingController,
    required this.editingFocus,
    required this.editingScrollController,
    required this.onMemo,
    required this.onBeginEdit,
    required this.onCommitEdit,
    required this.onLeadingControl,
  });

  final _DesktopPreviewColors colors;
  final WorkLap lap;
  final String elapsed;
  final SplitAccumulationMode splitMode;
  final bool selected;
  final bool active;
  final bool isEditing;
  final TextEditingController editingController;
  final FocusNode editingFocus;
  final ScrollController editingScrollController;
  final VoidCallback onMemo;
  final VoidCallback onBeginEdit;
  final VoidCallback onCommitEdit;
  final VoidCallback onLeadingControl;

  @override
  Widget build(BuildContext context) {
    final icon = splitMode == SplitAccumulationMode.radio
        ? (selected ? Icons.radio_button_checked : Icons.radio_button_unchecked)
        : (active ? Icons.check_box : Icons.check_box_outline_blank);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: colors.lapCard,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Row(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: onLeadingControl,
                child: Padding(
                  padding: const EdgeInsets.all(1),
                  child: Icon(icon, size: 12, color: colors.primaryText),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: isEditing
                    ? TextField(
                        controller: editingController,
                        focusNode: editingFocus,
                        scrollController: editingScrollController,
                        onSubmitted: (_) => onCommitEdit(),
                        textInputAction: TextInputAction.done,
                        maxLines: 1,
                        inputFormatters: const [_SingleLineTextFormatter()],
                        scrollPhysics: const ClampingScrollPhysics(),
                        style: TextStyle(
                          color: colors.primaryText,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          height: 1.06,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          fillColor: colors.inlineEditorBackground,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(4),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(4),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(4),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                        ),
                      )
                    : GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onBeginEdit,
                        child: Text(
                          '${lap.label}：',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.primaryText,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            height: 1.06,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Splitメモ',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 18,
                  height: 18,
                ),
                iconSize: 12,
                color: colors.utility,
                onPressed: onMemo,
                icon: Icon(
                  lap.memo.trim().isNotEmpty
                      ? Icons.sticky_note_2
                      : Icons.note_alt_outlined,
                ),
              ),
              const SizedBox(width: 3),
              Text(
                elapsed,
                style: TextStyle(
                  color: colors.primaryText,
                  fontSize: 13,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Container(
            height: 2,
            decoration: BoxDecoration(
              color: colors.lapColor(lap.index),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomActionRow extends StatelessWidget {
  const _BottomActionRow({
    required this.colors,
    required this.primaryLabel,
    required this.splitEnabled,
    required this.onPrimary,
    required this.onSplit,
    required this.onReset,
    required this.onDelete,
  });

  final _DesktopPreviewColors colors;
  final String primaryLabel;
  final bool splitEnabled;
  final VoidCallback onPrimary;
  final VoidCallback onSplit;
  final VoidCallback onReset;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          _TextActionButton(
            colors: colors,
            label: primaryLabel,
            prominent: true,
            onPressed: onPrimary,
          ),
          const SizedBox(width: 10),
          _TextActionButton(
            colors: colors,
            label: 'Split',
            enabled: splitEnabled,
            onPressed: onSplit,
          ),
          const Spacer(),
          _UtilityButton(
            colors: colors,
            icon: Icons.refresh,
            tooltip: 'リセット',
            onPressed: onReset,
          ),
          const SizedBox(width: 8),
          _UtilityButton(
            colors: colors,
            icon: Icons.delete_outline,
            tooltip: '現在セッションを削除',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _OverlayLayer extends StatelessWidget {
  const _OverlayLayer({
    required this.overlay,
    required this.colors,
    required this.sessions,
    required this.selectedSessionIndex,
    required this.isMonochrome,
    required this.ringHoursPerCycle,
    required this.defaultSplitMode,
    required this.selectedSummaryFormatId,
    required this.customSummaryFormats,
    required this.summaryTimeFormat,
    required this.summary,
    required this.summaryTimePreviewLabel,
    required this.shortcutsEnabled,
    required this.memoLabelController,
    required this.memoTextController,
    required this.summaryTextController,
    required this.memoElapsedText,
    required this.onClose,
    required this.onCloseMemo,
    required this.onOpenGuide,
    required this.onOpenContact,
    required this.onOpenContactMail,
    required this.onReset,
    required this.onDelete,
    required this.onSelectSession,
    required this.onSetTheme,
    required this.onSetRingHoursPerCycle,
    required this.onSetDefaultSplitMode,
    required this.onSetSummaryFormat,
    required this.onSaveCustomSummaryFormat,
    required this.onSaveCustomSummaryFormatFromSummary,
    required this.onDeleteCustomSummaryFormat,
    required this.onSetSummaryTimeFormat,
    required this.onSetSummaryFormatFromSummary,
    required this.onSetSummaryTimeFormatFromSummary,
    required this.onCopySummary,
    required this.onSetShortcutsEnabled,
    required this.onRequestLegacyImport,
    required this.onImportLegacyData,
    required this.onImportLegacyDataFromFile,
    required this.onQuitApp,
    required this.onDeleteSessionData,
    required this.onDeleteLapData,
    required this.onResetSettings,
    required this.onInitializeAllData,
  });

  final _PreviewOverlay overlay;
  final _DesktopPreviewColors colors;
  final List<String> sessions;
  final int selectedSessionIndex;
  final bool isMonochrome;
  final int ringHoursPerCycle;
  final SplitAccumulationMode defaultSplitMode;
  final String selectedSummaryFormatId;
  final List<SummaryFormatDefinition> customSummaryFormats;
  final _SummaryTimeFormat summaryTimeFormat;
  final _SessionSummary summary;
  final String summaryTimePreviewLabel;
  final bool shortcutsEnabled;
  final TextEditingController memoLabelController;
  final TextEditingController memoTextController;
  final TextEditingController summaryTextController;
  final String memoElapsedText;
  final VoidCallback onClose;
  final VoidCallback onCloseMemo;
  final VoidCallback onOpenGuide;
  final VoidCallback onOpenContact;
  final VoidCallback onOpenContactMail;
  final VoidCallback onReset;
  final VoidCallback onDelete;
  final ValueChanged<int> onSelectSession;
  final ValueChanged<bool> onSetTheme;
  final ValueChanged<int> onSetRingHoursPerCycle;
  final ValueChanged<SplitAccumulationMode> onSetDefaultSplitMode;
  final ValueChanged<String> onSetSummaryFormat;
  final ValueChanged<SummaryFormatDefinition> onSaveCustomSummaryFormat;
  final ValueChanged<SummaryFormatDefinition>
  onSaveCustomSummaryFormatFromSummary;
  final ValueChanged<String> onDeleteCustomSummaryFormat;
  final ValueChanged<_SummaryTimeFormat> onSetSummaryTimeFormat;
  final ValueChanged<String> onSetSummaryFormatFromSummary;
  final ValueChanged<_SummaryTimeFormat> onSetSummaryTimeFormatFromSummary;
  final VoidCallback onCopySummary;
  final ValueChanged<bool> onSetShortcutsEnabled;
  final VoidCallback onRequestLegacyImport;
  final VoidCallback onImportLegacyData;
  final VoidCallback onImportLegacyDataFromFile;
  final VoidCallback onQuitApp;
  final VoidCallback onDeleteSessionData;
  final VoidCallback onDeleteLapData;
  final VoidCallback onResetSettings;
  final VoidCallback onInitializeAllData;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (overlay == _PreviewOverlay.sessionList)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onClose,
              child: const SizedBox.expand(),
            ),
          ),
        if (overlay == _PreviewOverlay.sessionList)
          Positioned(
            right: 26,
            top: 46,
            child: _SessionOverflowPanel(
              colors: colors,
              sessions: sessions,
              selectedIndex: selectedSessionIndex,
              onSelect: onSelectSession,
            ),
          ),
        if (overlay == _PreviewOverlay.resetConfirmation)
          _ConfirmationOverlay(
            colors: colors,
            title: 'リセットしますか？',
            message: '現在表示中のセッションとSplitを初期状態に戻します。',
            confirmTitle: 'リセット',
            onClose: onClose,
            onConfirm: onReset,
          ),
        if (overlay == _PreviewOverlay.deleteConfirmation)
          _ConfirmationOverlay(
            colors: colors,
            title: 'セッションを削除しますか？',
            message: '現在表示中のセッションを削除します。',
            confirmTitle: '削除',
            destructive: true,
            onClose: onClose,
            onConfirm: onDelete,
          ),
        if (overlay == _PreviewOverlay.legacyImport)
          _ConfirmationOverlay(
            colors: colors,
            title: '旧SplitLogデータを取り込みますか？',
            message: '旧macOS版の sessions.json を読み込み、現在のFlutter版データとして保存します。',
            confirmTitle: 'インポート',
            onClose: onClose,
            onConfirm: onImportLegacyData,
          ),
        if (overlay == _PreviewOverlay.legacyImportMissing)
          _ConfirmationOverlay(
            colors: colors,
            title: '旧データが見つかりませんでした',
            message:
                '旧macOS版の sessions.json を読み込めませんでした。SplitLog(旧)のデータが存在するか確認してください。',
            confirmTitle: '閉じる',
            showCancel: false,
            onClose: onClose,
            onConfirm: onClose,
          ),
        if (overlay == _PreviewOverlay.memo)
          _CenteredOverlay(
            onClose: onCloseMemo,
            dismissOnBarrier: false,
            child: _MemoOverlay(
              colors: colors,
              labelController: memoLabelController,
              memoController: memoTextController,
              elapsedText: memoElapsedText,
              onClose: onCloseMemo,
            ),
          ),
        if (overlay == _PreviewOverlay.summary)
          _CenteredOverlay(
            onClose: onClose,
            dismissOnBarrier: false,
            child: _SummaryOverlay(
              colors: colors,
              summary: summary,
              selectedSummaryFormatId: selectedSummaryFormatId,
              customSummaryFormats: customSummaryFormats,
              selectedTimeFormat: summaryTimeFormat,
              summaryController: summaryTextController,
              onSelectSummaryFormat: onSetSummaryFormatFromSummary,
              onSaveCustomSummaryFormat: onSaveCustomSummaryFormatFromSummary,
              onSelectTimeFormat: onSetSummaryTimeFormatFromSummary,
              onCopy: onCopySummary,
              onClose: onClose,
            ),
          ),
        if (overlay == _PreviewOverlay.settings)
          _CenteredOverlay(
            onClose: onClose,
            child: _SettingsOverlay(
              colors: colors,
              isMonochrome: isMonochrome,
              onClose: onClose,
              onOpenGuide: onOpenGuide,
              onOpenContact: onOpenContact,
              ringHoursPerCycle: ringHoursPerCycle,
              defaultSplitMode: defaultSplitMode,
              selectedSummaryFormatId: selectedSummaryFormatId,
              customSummaryFormats: customSummaryFormats,
              summaryTimeFormat: summaryTimeFormat,
              summaryTimePreviewLabel: summaryTimePreviewLabel,
              shortcutsEnabled: shortcutsEnabled,
              onSetTheme: onSetTheme,
              onSetRingHoursPerCycle: onSetRingHoursPerCycle,
              onSetDefaultSplitMode: onSetDefaultSplitMode,
              onSetSummaryFormat: onSetSummaryFormat,
              onSaveCustomSummaryFormat: onSaveCustomSummaryFormat,
              onDeleteCustomSummaryFormat: onDeleteCustomSummaryFormat,
              onSetSummaryTimeFormat: onSetSummaryTimeFormat,
              onSetShortcutsEnabled: onSetShortcutsEnabled,
              onRequestLegacyImport: onRequestLegacyImport,
              onImportLegacyData: onImportLegacyData,
              onImportLegacyDataFromFile: onImportLegacyDataFromFile,
              onQuitApp: onQuitApp,
              onDeleteSessionData: onDeleteSessionData,
              onDeleteLapData: onDeleteLapData,
              onResetSettings: onResetSettings,
              onInitializeAllData: onInitializeAllData,
            ),
          ),
        if (overlay == _PreviewOverlay.help)
          _CenteredOverlay(
            onClose: onClose,
            child: _HelpOverlay(
              colors: colors,
              onClose: onClose,
              onOpenGuide: onOpenGuide,
              onOpenContact: onOpenContact,
            ),
          ),
        if (overlay == _PreviewOverlay.guide)
          _CenteredOverlay(
            onClose: onClose,
            child: _GuideOverlay(colors: colors, onClose: onClose),
          ),
        if (overlay == _PreviewOverlay.contact)
          _CenteredOverlay(
            onClose: onClose,
            child: _ContactOverlay(
              colors: colors,
              onClose: onClose,
              onOpenMail: onOpenContactMail,
            ),
          ),
      ],
    );
  }
}

class _CenteredOverlay extends StatelessWidget {
  const _CenteredOverlay({
    required this.child,
    required this.onClose,
    this.dismissOnBarrier = true,
  });

  final Widget child;
  final VoidCallback onClose;
  final bool dismissOnBarrier;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Stack(
        children: [
          GestureDetector(
            onTap: dismissOnBarrier ? onClose : null,
            behavior: HitTestBehavior.opaque,
            child: Container(color: Colors.transparent),
          ),
          Center(child: child),
        ],
      ),
    );
  }
}

class _SessionOverflowPanel extends StatelessWidget {
  const _SessionOverflowPanel({
    required this.colors,
    required this.sessions,
    required this.selectedIndex,
    required this.onSelect,
  });

  final _DesktopPreviewColors colors;
  final List<String> sessions;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.panelSurface,
      elevation: 16,
      shadowColor: Colors.black.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        key: const ValueKey<String>('session-overflow-panel'),
        width: 180,
        height: 260,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: colors.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: ListView.separated(
          padding: EdgeInsets.zero,
          itemCount: sessions.length,
          separatorBuilder: (_, _) => const SizedBox(height: 6),
          itemBuilder: (context, index) {
            final selected = index == selectedIndex;
            return _SessionMenuRow(
              colors: colors,
              title: sessions[index],
              selected: selected,
              onPressed: () => onSelect(index),
            );
          },
        ),
      ),
    );
  }
}

class _SessionMenuRow extends StatelessWidget {
  const _SessionMenuRow({
    required this.colors,
    required this.title,
    required this.selected,
    required this.onPressed,
  });

  final _DesktopPreviewColors colors;
  final String title;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onPressed,
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: selected ? colors.selectedChip : colors.menuRowBackground,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, color: colors.primaryText),
        ),
      ),
    );
  }
}

class _ConfirmationOverlay extends StatelessWidget {
  const _ConfirmationOverlay({
    required this.colors,
    required this.title,
    required this.message,
    required this.confirmTitle,
    required this.onClose,
    required this.onConfirm,
    this.destructive = false,
    this.showCancel = true,
  });

  final _DesktopPreviewColors colors;
  final String title;
  final String message;
  final String confirmTitle;
  final VoidCallback onClose;
  final VoidCallback onConfirm;
  final bool destructive;
  final bool showCancel;

  @override
  Widget build(BuildContext context) {
    return _CenteredOverlay(
      onClose: onClose,
      child: _ModalSurface(
        colors: colors,
        width: 320,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: TextStyle(fontSize: 11, color: colors.secondaryText),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (showCancel) ...[
                  _CompactDialogButton(
                    key: const ValueKey<String>('confirmation-cancel-button'),
                    colors: colors,
                    label: 'キャンセル',
                    onPressed: onClose,
                  ),
                  const SizedBox(width: 8),
                ],
                _CompactDialogButton(
                  key: const ValueKey<String>('confirmation-confirm-button'),
                  colors: colors,
                  label: confirmTitle,
                  onPressed: onConfirm,
                  prominent: true,
                  destructive: destructive,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MemoOverlay extends StatelessWidget {
  const _MemoOverlay({
    required this.colors,
    required this.labelController,
    required this.memoController,
    required this.elapsedText,
    required this.onClose,
  });

  final _DesktopPreviewColors colors;
  final TextEditingController labelController;
  final TextEditingController memoController;
  final String elapsedText;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return _ModalSurface(
      colors: colors,
      width: 360,
      height: 352,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Splitメモ',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Split名',
            style: TextStyle(fontSize: 11, color: colors.secondaryText),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: labelController,
            maxLines: 1,
            textInputAction: TextInputAction.done,
            inputFormatters: const [_SingleLineTextFormatter()],
            style: TextStyle(fontSize: 12, color: colors.primaryText),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: colors.memoFieldBackground,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 6,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: colors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: colors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: colors.border),
              ),
              hintText: '作業内容',
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '経過時間',
                style: TextStyle(fontSize: 11, color: colors.secondaryText),
              ),
              const Spacer(),
              Text(
                elapsedText,
                style: const TextStyle(
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'メモ',
            style: TextStyle(fontSize: 11, color: colors.secondaryText),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: TextField(
              controller: memoController,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                color: colors.primaryText,
              ),
              decoration: InputDecoration(
                filled: true,
                fillColor: colors.memoFieldBackground,
                contentPadding: const EdgeInsets.all(6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                  borderSide: BorderSide(color: colors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                  borderSide: BorderSide(color: colors.border),
                ),
                hintText: 'メモを入力',
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton(
                onPressed: onClose,
                style: colors.compactFilledButtonStyle(),
                child: const Text('閉じる'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryOverlay extends StatefulWidget {
  const _SummaryOverlay({
    required this.colors,
    required this.summary,
    required this.selectedSummaryFormatId,
    required this.customSummaryFormats,
    required this.selectedTimeFormat,
    required this.summaryController,
    required this.onSelectSummaryFormat,
    required this.onSaveCustomSummaryFormat,
    required this.onSelectTimeFormat,
    required this.onCopy,
    required this.onClose,
  });

  final _DesktopPreviewColors colors;
  final _SessionSummary summary;
  final String selectedSummaryFormatId;
  final List<SummaryFormatDefinition> customSummaryFormats;
  final _SummaryTimeFormat selectedTimeFormat;
  final TextEditingController summaryController;
  final ValueChanged<String> onSelectSummaryFormat;
  final ValueChanged<SummaryFormatDefinition> onSaveCustomSummaryFormat;
  final ValueChanged<_SummaryTimeFormat> onSelectTimeFormat;
  final VoidCallback onCopy;
  final VoidCallback onClose;

  @override
  State<_SummaryOverlay> createState() => _SummaryOverlayState();
}

class _SummaryOverlayState extends State<_SummaryOverlay> {
  SummaryFormatDefinition? _newSummaryFormat;

  @override
  Widget build(BuildContext context) {
    final newSummaryFormat = _newSummaryFormat;
    if (newSummaryFormat != null) {
      return _SummaryFormatEditor(
        key: ValueKey<String>(newSummaryFormat.id),
        colors: widget.colors,
        initialFormat: newSummaryFormat,
        canDelete: false,
        onCancel: () {
          setState(() {
            _newSummaryFormat = null;
          });
        },
        onSave: (format) {
          widget.onSaveCustomSummaryFormat(format);
          setState(() {
            _newSummaryFormat = null;
          });
        },
        onDelete: () {},
      );
    }

    return _ModalSurface(
      colors: widget.colors,
      width: 400,
      height: 352,
      child: Column(
        children: [
          Row(
            children: [
              const Text(
                'サマリー',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 6),
              _SummaryFormatPill(
                colors: widget.colors,
                selectedFormatId: widget.selectedSummaryFormatId,
                customFormats: widget.customSummaryFormats,
                onSelected: widget.onSelectSummaryFormat,
                onAdd: _beginNewSummaryFormat,
              ),
              const SizedBox(width: 5),
              _SummaryTimeFormatMenu(
                colors: widget.colors,
                selectedFormat: widget.selectedTimeFormat,
                previewLabel: widget.summary.timeFormatLabel,
                compact: true,
                onSelected: widget.onSelectTimeFormat,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.summary.headerText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: 10,
                    color: widget.colors.secondaryText,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _SummaryCopyButton(
                colors: widget.colors,
                onPressed: widget.onCopy,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: widget.summaryController,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: TextStyle(
                color: widget.colors.primaryText,
                fontSize: 12,
                height: 1.3,
              ),
              decoration: InputDecoration(
                filled: true,
                fillColor: widget.colors.memoFieldBackground,
                contentPadding: const EdgeInsets.all(8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                  borderSide: BorderSide(color: widget.colors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                  borderSide: BorderSide(color: widget.colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                  borderSide: BorderSide(color: widget.colors.border),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton(
                onPressed: widget.onClose,
                style: widget.colors.compactFilledButtonStyle(),
                child: const Text('閉じる'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _beginNewSummaryFormat() {
    setState(() {
      _newSummaryFormat = _createCustomSummaryFormatDraft(
        widget.customSummaryFormats,
      );
    });
  }
}

class _SettingsOverlay extends StatefulWidget {
  const _SettingsOverlay({
    required this.colors,
    required this.isMonochrome,
    required this.onClose,
    required this.onOpenGuide,
    required this.onOpenContact,
    required this.ringHoursPerCycle,
    required this.defaultSplitMode,
    required this.selectedSummaryFormatId,
    required this.customSummaryFormats,
    required this.summaryTimeFormat,
    required this.summaryTimePreviewLabel,
    required this.shortcutsEnabled,
    required this.onSetTheme,
    required this.onSetRingHoursPerCycle,
    required this.onSetDefaultSplitMode,
    required this.onSetSummaryFormat,
    required this.onSaveCustomSummaryFormat,
    required this.onDeleteCustomSummaryFormat,
    required this.onSetSummaryTimeFormat,
    required this.onSetShortcutsEnabled,
    required this.onRequestLegacyImport,
    required this.onImportLegacyData,
    required this.onImportLegacyDataFromFile,
    required this.onQuitApp,
    required this.onDeleteSessionData,
    required this.onDeleteLapData,
    required this.onResetSettings,
    required this.onInitializeAllData,
  });

  final _DesktopPreviewColors colors;
  final bool isMonochrome;
  final VoidCallback onClose;
  final VoidCallback onOpenGuide;
  final VoidCallback onOpenContact;
  final int ringHoursPerCycle;
  final SplitAccumulationMode defaultSplitMode;
  final String selectedSummaryFormatId;
  final List<SummaryFormatDefinition> customSummaryFormats;
  final _SummaryTimeFormat summaryTimeFormat;
  final String summaryTimePreviewLabel;
  final bool shortcutsEnabled;
  final ValueChanged<bool> onSetTheme;
  final ValueChanged<int> onSetRingHoursPerCycle;
  final ValueChanged<SplitAccumulationMode> onSetDefaultSplitMode;
  final ValueChanged<String> onSetSummaryFormat;
  final ValueChanged<SummaryFormatDefinition> onSaveCustomSummaryFormat;
  final ValueChanged<String> onDeleteCustomSummaryFormat;
  final ValueChanged<_SummaryTimeFormat> onSetSummaryTimeFormat;
  final ValueChanged<bool> onSetShortcutsEnabled;
  final VoidCallback onRequestLegacyImport;
  final VoidCallback onImportLegacyData;
  final VoidCallback onImportLegacyDataFromFile;
  final VoidCallback onQuitApp;
  final VoidCallback onDeleteSessionData;
  final VoidCallback onDeleteLapData;
  final VoidCallback onResetSettings;
  final VoidCallback onInitializeAllData;

  Widget buildModal(
    BuildContext context, {
    required ValueChanged<_SettingsStorageAction> onRequestStorageAction,
    required VoidCallback onAddSummaryFormat,
    required ValueChanged<SummaryFormatDefinition> onEditSummaryFormat,
  }) {
    return _ModalSurface(
      colors: colors,
      width: 360,
      height: 360,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '設定',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: _CompactScrollbarTheme(
              child: ListView(
                key: const ValueKey<String>('settings-scroll-view'),
                padding: const EdgeInsets.only(right: _desktopScrollbarGutter),
                children: [
                  _SettingsGroup(
                    colors: colors,
                    label: 'テーマカラー',
                    children: [
                      _SettingsRow(
                        colors: colors,
                        title: 'テーマカラー',
                        trailing: SizedBox(
                          width: 140,
                          child: _ChoiceBar(
                            colors: colors,
                            selectedIndex: isMonochrome ? 1 : 0,
                            labels: const ['カラー', 'モノクロ'],
                            onTap: (index) => onSetTheme(index == 1),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SettingsGroup(
                    colors: colors,
                    label: '表示',
                    children: [
                      _SettingsRow(
                        colors: colors,
                        title: 'リング周期（1周）',
                        trailing: _InlineStepperValue(
                          value: '$ringHoursPerCycle時間',
                          onDecrease: () =>
                              onSetRingHoursPerCycle(ringHoursPerCycle - 1),
                          onIncrease: () =>
                              onSetRingHoursPerCycle(ringHoursPerCycle + 1),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _SectionLabel(
                        colors: colors,
                        label: '新規セッションのデフォルトSplit配分モード',
                      ),
                      const SizedBox(height: 6),
                      _SettingsRow(
                        colors: colors,
                        title: 'デフォルト分配モード',
                        trailing: SizedBox(
                          width: 140,
                          child: _ChoiceBar(
                            colors: colors,
                            selectedIndex:
                                defaultSplitMode == SplitAccumulationMode.radio
                                ? 0
                                : 1,
                            labels: const ['ラジオ', 'チェック'],
                            onTap: (index) => onSetDefaultSplitMode(
                              index == 0
                                  ? SplitAccumulationMode.radio
                                  : SplitAccumulationMode.checkbox,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '新しく追加するセッションの初期値として使います。',
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.secondaryText,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SettingsGroup(
                    colors: colors,
                    label: 'サマリー表示',
                    children: [
                      _SettingsRow(
                        colors: colors,
                        title: 'サマリー表示フォーマット',
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _SummaryFormatMenu(
                              colors: colors,
                              selectedFormatId: selectedSummaryFormatId,
                              customFormats: customSummaryFormats,
                              onSelected: onSetSummaryFormat,
                              onAdd: onAddSummaryFormat,
                            ),
                            const SizedBox(width: 5),
                            _SummaryFormatEditButton(
                              colors: colors,
                              selectedFormat: resolveSummaryFormat(
                                selectedSummaryFormatId,
                                customSummaryFormats,
                              ),
                              onAdd: onAddSummaryFormat,
                              onEdit: onEditSummaryFormat,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      _SettingsRow(
                        colors: colors,
                        title: '時間表示形式',
                        trailing: _SummaryTimeFormatMenu(
                          colors: colors,
                          selectedFormat: summaryTimeFormat,
                          previewLabel: summaryTimePreviewLabel,
                          onSelected: onSetSummaryTimeFormat,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SettingsGroup(
                    colors: colors,
                    label: 'ショートカット',
                    children: [
                      _SettingsRow(
                        colors: colors,
                        title: 'グローバルショートカット',
                        trailing: SizedBox(
                          width: 140,
                          child: _ChoiceBar(
                            colors: colors,
                            selectedIndex: shortcutsEnabled ? 0 : 1,
                            labels: const ['オン', 'オフ'],
                            onTap: (index) => onSetShortcutsEnabled(index == 0),
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Desktop版のみ、⌘⌃Sなどのグローバルショートカットを使います。',
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.secondaryText,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SettingsGroup(
                    colors: colors,
                    label: '案内',
                    children: [
                      _ActionRow(
                        colors: colors,
                        title: '操作説明',
                        icon: Icons.question_mark,
                        onPressed: onOpenGuide,
                      ),
                      const SizedBox(height: 6),
                      _ActionRow(
                        colors: colors,
                        title: 'お問い合わせ',
                        icon: Icons.mail_outline,
                        onPressed: onOpenContact,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SettingsGroup(
                    colors: colors,
                    label: 'ストレージ管理',
                    children: [
                      _ActionRow(
                        colors: colors,
                        title: '旧データをインポート',
                        icon: Icons.file_download_outlined,
                        onPressed: onRequestLegacyImport,
                      ),
                      const SizedBox(height: 6),
                      _ActionRow(
                        colors: colors,
                        title: 'sessions.jsonを選択',
                        icon: Icons.folder_open,
                        onPressed: onImportLegacyDataFromFile,
                      ),
                      const SizedBox(height: 6),
                      _ActionRow(
                        colors: colors,
                        title: 'セッション情報',
                        icon: Icons.delete_outline,
                        destructive: true,
                        onPressed: () => onRequestStorageAction(
                          _SettingsStorageAction.deleteSessionData,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _ActionRow(
                        colors: colors,
                        title: 'Split情報',
                        icon: Icons.delete_outline,
                        destructive: true,
                        onPressed: () => onRequestStorageAction(
                          _SettingsStorageAction.deleteLapData,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _ActionRow(
                        colors: colors,
                        title: '設定のみ初期化',
                        icon: Icons.refresh,
                        onPressed: () => onRequestStorageAction(
                          _SettingsStorageAction.resetSettings,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _ActionRow(
                        colors: colors,
                        title: '全データ初期化',
                        icon: Icons.warning_amber,
                        destructive: true,
                        onPressed: () => onRequestStorageAction(
                          _SettingsStorageAction.initializeAllData,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SettingsGroup(
                    colors: colors,
                    label: 'アプリ',
                    children: [
                      _ActionRow(
                        colors: colors,
                        title: 'SplitLogを終了',
                        icon: Icons.power_settings_new,
                        onPressed: onQuitApp,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _CompactDialogButton(
                colors: colors,
                label: '閉じる',
                onPressed: onClose,
                prominent: true,
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  State<_SettingsOverlay> createState() => _SettingsOverlayState();
}

class _SettingsOverlayState extends State<_SettingsOverlay> {
  _SettingsStorageAction? _pendingStorageAction;
  SummaryFormatDefinition? _editingSummaryFormat;
  bool _editingNewSummaryFormat = false;
  bool _confirmSummaryFormatDelete = false;

  @override
  Widget build(BuildContext context) {
    final action = _pendingStorageAction;
    final editingFormat = _editingSummaryFormat;
    return SizedBox(
      width: 540,
      height: 380,
      child: Stack(
        children: [
          Center(
            child: editingFormat == null
                ? widget.buildModal(
                    context,
                    onRequestStorageAction: (requestedAction) {
                      setState(() {
                        _pendingStorageAction = requestedAction;
                      });
                    },
                    onAddSummaryFormat: _beginNewSummaryFormat,
                    onEditSummaryFormat: _beginEditSummaryFormat,
                  )
                : _SummaryFormatEditor(
                    key: ValueKey<String>(editingFormat.id),
                    colors: widget.colors,
                    initialFormat: editingFormat,
                    canDelete: !_editingNewSummaryFormat,
                    onCancel: () {
                      setState(() {
                        _editingSummaryFormat = null;
                        _editingNewSummaryFormat = false;
                      });
                    },
                    onSave: (format) {
                      widget.onSaveCustomSummaryFormat(format);
                      setState(() {
                        _editingSummaryFormat = null;
                        _editingNewSummaryFormat = false;
                      });
                    },
                    onDelete: () {
                      setState(() {
                        _confirmSummaryFormatDelete = true;
                      });
                    },
                  ),
          ),
          if (action != null)
            _ConfirmationOverlay(
              colors: widget.colors,
              title: action.title,
              message: action.message,
              confirmTitle: action.confirmTitle,
              destructive: action.isDestructive,
              onClose: () {
                setState(() {
                  _pendingStorageAction = null;
                });
              },
              onConfirm: () {
                _performStorageAction(action);
                setState(() {
                  _pendingStorageAction = null;
                });
              },
            ),
          if (_confirmSummaryFormatDelete && editingFormat != null)
            _ConfirmationOverlay(
              colors: widget.colors,
              title: '${editingFormat.name}を削除しますか？',
              message: 'このカスタムフォーマットと置換ルールを削除します。',
              confirmTitle: '削除',
              destructive: true,
              onClose: () {
                setState(() {
                  _confirmSummaryFormatDelete = false;
                });
              },
              onConfirm: () {
                widget.onDeleteCustomSummaryFormat(editingFormat.id);
                setState(() {
                  _confirmSummaryFormatDelete = false;
                  _editingSummaryFormat = null;
                  _editingNewSummaryFormat = false;
                });
              },
            ),
        ],
      ),
    );
  }

  void _beginNewSummaryFormat() {
    setState(() {
      _editingSummaryFormat = _createCustomSummaryFormatDraft(
        widget.customSummaryFormats,
      );
      _editingNewSummaryFormat = true;
    });
  }

  void _beginEditSummaryFormat(SummaryFormatDefinition format) {
    if (format.isBuiltIn) {
      _beginNewSummaryFormat();
      return;
    }
    setState(() {
      _editingSummaryFormat = format;
      _editingNewSummaryFormat = false;
    });
  }

  void _performStorageAction(_SettingsStorageAction action) {
    switch (action) {
      case _SettingsStorageAction.deleteSessionData:
        widget.onDeleteSessionData();
        break;
      case _SettingsStorageAction.deleteLapData:
        widget.onDeleteLapData();
        break;
      case _SettingsStorageAction.resetSettings:
        widget.onResetSettings();
        break;
      case _SettingsStorageAction.initializeAllData:
        widget.onInitializeAllData();
        break;
    }
  }
}

class _SummaryFormatEditor extends StatefulWidget {
  const _SummaryFormatEditor({
    super.key,
    required this.colors,
    required this.initialFormat,
    required this.canDelete,
    required this.onCancel,
    required this.onSave,
    required this.onDelete,
  });

  final _DesktopPreviewColors colors;
  final SummaryFormatDefinition initialFormat;
  final bool canDelete;
  final VoidCallback onCancel;
  final ValueChanged<SummaryFormatDefinition> onSave;
  final VoidCallback onDelete;

  @override
  State<_SummaryFormatEditor> createState() => _SummaryFormatEditorState();
}

class _SummaryFormatEditorState extends State<_SummaryFormatEditor> {
  late final TextEditingController _nameController;
  late final TextEditingController _titleTemplateController;
  late final TextEditingController _timeTemplateController;
  late final TextEditingController _memoTemplateController;
  late final TextEditingController _exampleTitleController;
  late final TextEditingController _exampleTimeController;
  late final TextEditingController _exampleMemoController;
  final List<_SummaryRuleControllers> _rules = [];
  var _nextRuleNumber = 0;

  @override
  void initState() {
    super.initState();
    _nameController = _controller(widget.initialFormat.name);
    _titleTemplateController = _controller(widget.initialFormat.titleTemplate);
    _timeTemplateController = _controller(widget.initialFormat.timeTemplate);
    _memoTemplateController = _controller(widget.initialFormat.memoTemplate);
    _exampleTitleController = _controller('API実装');
    _exampleTimeController = _controller('1.10h');
    _exampleMemoController = _controller(
      '午前中に資料作成を進めました。\\n確認が必要な箇所を整理しました。\n'
      '午後は打ち合わせの内容をまとめます。',
    );
    for (final rule in widget.initialFormat.rules) {
      _rules.add(_ruleControllers(rule));
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _titleTemplateController.dispose();
    _timeTemplateController.dispose();
    _memoTemplateController.dispose();
    _exampleTitleController.dispose();
    _exampleTimeController.dispose();
    _exampleMemoController.dispose();
    for (final rule in _rules) {
      rule.dispose();
    }
    super.dispose();
  }

  TextEditingController _controller(String value) {
    final controller = TextEditingController(
      text: _encodeVisibleWhitespace(value),
    );
    controller.addListener(_refreshPreview);
    return controller;
  }

  _SummaryRuleControllers _ruleControllers(SummaryReplacementRule rule) {
    _nextRuleNumber += 1;
    return _SummaryRuleControllers(
      id: rule.id.isEmpty
          ? 'rule-${DateTime.now().microsecondsSinceEpoch}-$_nextRuleNumber'
          : rule.id,
      matchController: _controller(rule.match),
      replacementController: _controller(rule.replacement),
    );
  }

  void _refreshPreview() {
    if (mounted) {
      setState(() {});
    }
  }

  SummaryFormatDefinition get _draftFormat {
    final name = _decodeVisibleWhitespace(_nameController.text).trim();
    return widget.initialFormat.copyWith(
      name: name.isEmpty ? widget.initialFormat.name : name,
      titleTemplate: _decodeVisibleWhitespace(_titleTemplateController.text),
      timeTemplate: _decodeVisibleWhitespace(_timeTemplateController.text),
      memoTemplate: _decodeVisibleWhitespace(_memoTemplateController.text),
      rules: [
        for (final rule in _rules)
          SummaryReplacementRule(
            id: rule.id,
            match: _decodeVisibleWhitespace(rule.matchController.text),
            replacement: _decodeVisibleWhitespace(
              rule.replacementController.text,
            ),
          ),
      ],
    );
  }

  String get _previewText {
    return renderSummaryEntry(
      format: _draftFormat,
      title: _decodeVisibleWhitespace(_exampleTitleController.text),
      time: _decodeVisibleWhitespace(_exampleTimeController.text),
      memo: _decodeVisibleWhitespace(_exampleMemoController.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return _ModalSurface(
      colors: colors,
      width: 540,
      height: 376,
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              const Text(
                'カスタムフォーマット',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                '␣ 半角  □ 全角',
                style: TextStyle(fontSize: 10, color: colors.secondaryText),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  key: const ValueKey<String>('summary-format-preview-column'),
                  width: 276,
                  child: _buildPreviewColumn(colors),
                ),
                const SizedBox(width: 10),
                VerticalDivider(width: 1, color: colors.border),
                const SizedBox(width: 10),
                Expanded(
                  key: const ValueKey<String>('summary-format-editor-column'),
                  child: _buildEditorColumn(colors),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (widget.canDelete)
                _CompactDialogButton(
                  colors: colors,
                  label: '削除',
                  destructive: true,
                  onPressed: widget.onDelete,
                ),
              const Spacer(),
              _CompactDialogButton(
                colors: colors,
                label: 'キャンセル',
                onPressed: widget.onCancel,
              ),
              const SizedBox(width: 8),
              _CompactDialogButton(
                colors: colors,
                label: '保存',
                prominent: true,
                onPressed: () => widget.onSave(_draftFormat),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewColumn(_DesktopPreviewColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FormatSectionHeading(
          colors: colors,
          icon: Icons.edit_outlined,
          label: '入力例',
        ),
        const SizedBox(height: 5),
        _EditorField(
          colors: colors,
          controller: _exampleTitleController,
          label: 'Split名',
          fieldKey: const ValueKey<String>('format-example-title-field'),
        ),
        const SizedBox(height: 5),
        _EditorField(
          colors: colors,
          controller: _exampleTimeController,
          label: '作業時間',
          fieldKey: const ValueKey<String>('format-example-time-field'),
        ),
        const SizedBox(height: 5),
        _EditorField(
          colors: colors,
          controller: _exampleMemoController,
          label: 'メモ',
          maxLines: 3,
          fieldKey: const ValueKey<String>('format-example-memo-field'),
        ),
        const SizedBox(height: 7),
        _FormatSectionHeading(
          colors: colors,
          icon: Icons.visibility_outlined,
          label: 'プレビュー',
        ),
        const SizedBox(height: 5),
        Expanded(
          child: Container(
            key: const ValueKey<String>('summary-format-preview'),
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.82),
              border: Border(
                left: BorderSide(
                  color: colors.accent.withValues(alpha: 0.72),
                  width: 2,
                ),
              ),
            ),
            child: SingleChildScrollView(
              child: Text(
                _previewText,
                style: TextStyle(
                  color: colors.primaryText,
                  fontSize: 10,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEditorColumn(_DesktopPreviewColors colors) {
    return _CompactScrollbarTheme(
      child: ListView(
        key: const ValueKey<String>('summary-format-editor-scroll-view'),
        padding: const EdgeInsets.only(right: _desktopScrollbarGutter),
        children: [
          _FormatSectionHeading(
            colors: colors,
            icon: Icons.tune,
            label: '表示形式',
          ),
          const SizedBox(height: 5),
          _EditorField(
            colors: colors,
            controller: _nameController,
            label: 'フォーマット名',
            fieldKey: const ValueKey<String>('format-name-field'),
          ),
          const SizedBox(height: 7),
          _TemplateEditorField(
            colors: colors,
            controller: _titleTemplateController,
            label: 'タイトル表示',
            token: '{title}',
            fieldKey: const ValueKey<String>('format-title-template-field'),
          ),
          const SizedBox(height: 7),
          _TemplateEditorField(
            colors: colors,
            controller: _timeTemplateController,
            label: '作業時間表示',
            token: '{time}',
            fieldKey: const ValueKey<String>('format-time-template-field'),
          ),
          const SizedBox(height: 7),
          _TemplateEditorField(
            colors: colors,
            controller: _memoTemplateController,
            label: 'メモ表示',
            token: '{memo}',
            fieldKey: const ValueKey<String>('format-memo-template-field'),
          ),
          const SizedBox(height: 10),
          _FormatSectionHeading(
            colors: colors,
            icon: Icons.find_replace,
            label: '置換ルール',
            trailing: _AddRuleButton(colors: colors, onPressed: _addRule),
          ),
          const SizedBox(height: 5),
          if (_rules.isEmpty)
            Text(
              'ルールなし',
              style: TextStyle(fontSize: 10, color: colors.secondaryText),
            ),
          for (var index = 0; index < _rules.length; index += 1) ...[
            _buildRuleEditor(colors, index),
            if (index != _rules.length - 1) const SizedBox(height: 7),
          ],
        ],
      ),
    );
  }

  Widget _buildRuleEditor(_DesktopPreviewColors colors, int index) {
    final rule = _rules[index];
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.56),
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                'ルール ${index + 1}',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: colors.primaryText,
                ),
              ),
              const Spacer(),
              _MiniIconButton(
                colors: colors,
                icon: Icons.keyboard_arrow_up,
                tooltip: '上へ移動',
                enabled: index > 0,
                onPressed: () => _moveRule(index, -1),
              ),
              const SizedBox(width: 3),
              _MiniIconButton(
                colors: colors,
                icon: Icons.keyboard_arrow_down,
                tooltip: '下へ移動',
                enabled: index < _rules.length - 1,
                onPressed: () => _moveRule(index, 1),
              ),
              const SizedBox(width: 3),
              _MiniIconButton(
                colors: colors,
                icon: Icons.delete_outline,
                tooltip: 'ルールを削除',
                destructive: true,
                onPressed: () => _removeRule(index),
              ),
            ],
          ),
          const SizedBox(height: 5),
          _EditorField(
            colors: colors,
            controller: rule.matchController,
            label: '検索文字列',
            maxLines: 3,
            fieldKey: ValueKey<String>('format-rule-match-$index'),
          ),
          const SizedBox(height: 5),
          _TemplateEditorField(
            colors: colors,
            controller: rule.replacementController,
            label: '置換文字列',
            token: '{match}',
            fieldKey: ValueKey<String>('format-rule-replacement-$index'),
          ),
        ],
      ),
    );
  }

  void _addRule() {
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    setState(() {
      _rules.add(
        _ruleControllers(
          SummaryReplacementRule(
            id: 'rule-$timestamp-$_nextRuleNumber',
            match: '',
            replacement: '',
          ),
        ),
      );
    });
  }

  void _removeRule(int index) {
    final removed = _rules.removeAt(index);
    removed.dispose();
    setState(() {});
  }

  void _moveRule(int index, int offset) {
    final target = index + offset;
    if (target < 0 || target >= _rules.length) {
      return;
    }
    setState(() {
      final rule = _rules.removeAt(index);
      _rules.insert(target, rule);
    });
  }
}

class _SummaryRuleControllers {
  const _SummaryRuleControllers({
    required this.id,
    required this.matchController,
    required this.replacementController,
  });

  final String id;
  final TextEditingController matchController;
  final TextEditingController replacementController;

  void dispose() {
    matchController.dispose();
    replacementController.dispose();
  }
}

class _CompactScrollbarTheme extends StatelessWidget {
  const _CompactScrollbarTheme({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ScrollbarTheme(
      data: ScrollbarTheme.of(context).copyWith(
        thickness: const WidgetStatePropertyAll<double?>(
          _compactScrollbarThickness,
        ),
        radius: const Radius.circular(3),
      ),
      child: child,
    );
  }
}

class _FormatSectionHeading extends StatelessWidget {
  const _FormatSectionHeading({
    required this.colors,
    required this.icon,
    required this.label,
    this.trailing,
  });

  final _DesktopPreviewColors colors;
  final IconData icon;
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 18,
      child: Row(
        children: [
          Icon(icon, size: 12, color: colors.accent),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: colors.primaryText,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }
}

class _AddRuleButton extends StatelessWidget {
  const _AddRuleButton({required this.colors, required this.onPressed});

  final _DesktopPreviewColors colors;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'ルールを追加',
      child: InkWell(
        key: const ValueKey<String>('format-add-rule-button'),
        borderRadius: BorderRadius.circular(4),
        mouseCursor: SystemMouseCursors.click,
        hoverColor: colors.accent.withValues(alpha: 0.10),
        onTap: onPressed,
        child: Ink(
          height: 18,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: 0.08),
            border: Border.all(color: colors.accent.withValues(alpha: 0.38)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 10, color: colors.accent),
              const SizedBox(width: 2),
              Text(
                'ルール',
                style: TextStyle(
                  color: colors.accent,
                  fontSize: 10,
                  height: 1,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditorField extends StatelessWidget {
  const _EditorField({
    required this.colors,
    required this.controller,
    required this.label,
    this.maxLines = 1,
    this.fieldKey,
  });

  final _DesktopPreviewColors colors;
  final TextEditingController controller;
  final String label;
  final int maxLines;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: colors.primaryText.withValues(alpha: 0.72),
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 3),
        TextField(
          key: fieldKey,
          controller: controller,
          minLines: 1,
          maxLines: maxLines,
          textInputAction: maxLines == 1
              ? TextInputAction.done
              : TextInputAction.newline,
          inputFormatters: const [_VisibleWhitespaceFormatter()],
          style: TextStyle(
            color: colors.primaryText,
            fontSize: 10,
            height: 1.25,
          ),
          decoration: _editorInputDecoration(colors),
        ),
      ],
    );
  }
}

class _TemplateEditorField extends StatelessWidget {
  const _TemplateEditorField({
    required this.colors,
    required this.controller,
    required this.label,
    required this.token,
    this.fieldKey,
  });

  final _DesktopPreviewColors colors;
  final TextEditingController controller;
  final String label;
  final String token;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: colors.primaryText.withValues(alpha: 0.72),
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            _TokenButton(
              colors: colors,
              token: token,
              onPressed: () => _insertToken(controller, token),
            ),
          ],
        ),
        const SizedBox(height: 3),
        TextField(
          key: fieldKey,
          controller: controller,
          minLines: 1,
          maxLines: 3,
          textInputAction: TextInputAction.newline,
          inputFormatters: const [_VisibleWhitespaceFormatter()],
          style: TextStyle(
            color: colors.primaryText,
            fontSize: 10,
            height: 1.25,
          ),
          decoration: _editorInputDecoration(colors),
        ),
      ],
    );
  }
}

class _TokenButton extends StatelessWidget {
  const _TokenButton({
    required this.colors,
    required this.token,
    required this.onPressed,
  });

  final _DesktopPreviewColors colors;
  final String token;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$tokenを入力欄へ挿入',
      child: InkWell(
        key: ValueKey<String>('format-token-$token'),
        borderRadius: BorderRadius.circular(3),
        mouseCursor: SystemMouseCursors.click,
        hoverColor: colors.accent.withValues(alpha: 0.14),
        onTap: onPressed,
        child: Ink(
          height: 16,
          padding: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: 0.08),
            border: Border.all(color: colors.accent.withValues(alpha: 0.42)),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.add, size: 8, color: colors.accent),
              const SizedBox(width: 1),
              Text(
                token,
                style: TextStyle(
                  fontSize: 10,
                  height: 1,
                  color: colors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniIconButton extends StatelessWidget {
  const _MiniIconButton({
    required this.colors,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.enabled = true,
    this.destructive = false,
  });

  final _DesktopPreviewColors colors;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool enabled;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? colors.softText
        : destructive
        ? const Color(0xFFC94848)
        : colors.utility;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: enabled ? onPressed : null,
        child: SizedBox(
          width: 20,
          height: 20,
          child: Icon(icon, size: 13, color: color),
        ),
      ),
    );
  }
}

InputDecoration _editorInputDecoration(_DesktopPreviewColors colors) {
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(5),
    borderSide: BorderSide(color: colors.border),
  );
  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: colors.memoFieldBackground,
    contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
    border: border,
    enabledBorder: border,
    focusedBorder: border,
  );
}

void _insertToken(TextEditingController controller, String token) {
  final selection = controller.selection;
  final start = selection.isValid ? selection.start : controller.text.length;
  final end = selection.isValid ? selection.end : controller.text.length;
  controller.value = TextEditingValue(
    text: controller.text.replaceRange(start, end, token),
    selection: TextSelection.collapsed(offset: start + token.length),
  );
}

class _VisibleWhitespaceFormatter extends TextInputFormatter {
  const _VisibleWhitespaceFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final encoded = _encodeVisibleWhitespace(newValue.text);
    if (encoded == newValue.text) {
      return newValue;
    }
    return newValue.copyWith(
      text: encoded,
      selection: TextSelection(
        baseOffset: newValue.selection.baseOffset.clamp(0, encoded.length),
        extentOffset: newValue.selection.extentOffset.clamp(0, encoded.length),
      ),
      composing: newValue.composing.isValid
          ? TextRange(
              start: newValue.composing.start.clamp(0, encoded.length),
              end: newValue.composing.end.clamp(0, encoded.length),
            )
          : TextRange.empty,
    );
  }
}

String _encodeVisibleWhitespace(String value) {
  return value
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('　', '□')
      .replaceAll(' ', '␣');
}

String _decodeVisibleWhitespace(String value) {
  return value.replaceAll('␣', ' ').replaceAll('□', '　');
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({
    required this.colors,
    required this.label,
    required this.children,
  });

  final _DesktopPreviewColors colors;
  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(colors: colors, label: label),
        const SizedBox(height: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ],
    );
  }
}

class _ChoiceBar extends StatelessWidget {
  const _ChoiceBar({
    required this.colors,
    required this.labels,
    required this.selectedIndex,
    required this.onTap,
  });

  final _DesktopPreviewColors colors;
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colors.headerControl,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          for (var index = 0; index < labels.length; index += 1)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(5),
                onTap: () => onTap(index),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: index == selectedIndex
                        ? colors.panelSurface
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: index == selectedIndex
                          ? colors.border
                          : Colors.transparent,
                    ),
                  ),
                  child: Text(
                    labels[index],
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: index == selectedIndex
                          ? FontWeight.w500
                          : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HelpOverlay extends StatelessWidget {
  const _HelpOverlay({
    required this.colors,
    required this.onClose,
    required this.onOpenGuide,
    required this.onOpenContact,
  });

  final _DesktopPreviewColors colors;
  final VoidCallback onClose;
  final VoidCallback onOpenGuide;
  final VoidCallback onOpenContact;

  @override
  Widget build(BuildContext context) {
    return _ModalSurface(
      colors: colors,
      width: 300,
      padding: const EdgeInsets.all(16),
      borderRadius: 18,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text(
                '案内',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              _OverlayCloseButton(colors: colors, onPressed: onClose),
            ],
          ),
          const SizedBox(height: 14),
          _HelpCard(
            colors: colors,
            title: '操作説明',
            subtitle: 'このアプリでできることと使い方を確認',
            icon: Icons.question_mark,
            onPressed: onOpenGuide,
          ),
          const SizedBox(height: 10),
          _HelpCard(
            colors: colors,
            title: 'お問い合わせ',
            subtitle: '不具合報告や相談用の導線',
            icon: Icons.mail_outline,
            onPressed: onOpenContact,
          ),
        ],
      ),
    );
  }
}

class _GuideOverlay extends StatefulWidget {
  const _GuideOverlay({required this.colors, required this.onClose});

  final _DesktopPreviewColors colors;
  final VoidCallback onClose;

  @override
  State<_GuideOverlay> createState() => _GuideOverlayState();
}

class _GuideOverlayState extends State<_GuideOverlay> {
  static List<_GuideSection> get _sections {
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    final shortcutPrefix = isWindows ? 'Ctrl+Alt+' : '⌘⌃';
    return [
      _GuideSection(
        title: '計測を始める・区切る',
        summary: '開始・停止・再開と Split の基本操作',
        details: [
          '開始で計測を始め、停止と再開で同じセッションの計測を続けます。',
          '計測中に Split を押すと現在の区切りを確定し、次の Split を作成します。',
          '中央の全体経過と左側のリングで、セッション全体の経過時間を確認できます。',
        ],
      ),
      _GuideSection(
        title: 'セッションを管理する',
        summary: '切り替え・追加・名前変更・整理',
        details: [
          '上部の一覧または三点ボタンから、表示するセッションを切り替えられます。',
          '表示中のセッション名をクリックすると、名前を編集できます。',
          'プラスボタンで新しいセッションを追加します。追加や切り替えを行うと、計測中のセッションは停止します。',
          'リセットは現在の内容だけを初期化し、削除はセッション自体を取り除きます。どちらも実行前に確認が表示されます。',
        ],
      ),
      _GuideSection(
        title: 'Split を編集・配分する',
        summary: '名前の編集と時間の割り当て方法',
        details: [
          'Split 名をクリックすると、その場で名前を編集できます。',
          'ラジオ配分では、選択中の Split に経過時間が加算されます。',
          'チェック配分では、チェックした Split に経過秒を順番に分配します。複数の Split に同じ時間は重複加算されません。',
          '配分モードは、サマリーボタン左のアイコンから切り替えます。',
        ],
      ),
      _GuideSection(
        title: 'メモを記録する',
        summary: 'Split ごとの作業内容を残す',
        details: [
          '各 Split のメモアイコンから、Split 名とメモを編集できます。',
          'メモ画面には、その Split に割り当てられた経過時間も表示されます。',
          '閉じるボタンで編集内容を確定し、端末内へ保存します。',
        ],
      ),
      _GuideSection(
        title: 'サマリーを作成する',
        summary: '作業記録を整えてコピーする',
        details: [
          'サマリーボタンで、表示中のセッションから一覧テキストを作成します。',
          'サマリー本文はコピー前に直接編集できるため、共有先に合わせて手直しできます。',
          '上部の表示形式ボタンで書式を、時間ボタンで時間・h（小数第1位まで）・h（小数第2位まで）を選べます。',
          'コピーボタンで、表示中のサマリーをクリップボードへコピーします。',
        ],
      ),
      _GuideSection(
        title: 'サマリー表示をカスタマイズする',
        summary: 'タイトル・時間・メモの書式と置換ルール',
        details: [
          'サマリーの表示形式ボタンまたは設定から、標準・テンプレート・作成済みのカスタムを選べます。',
          'カスタムでは {title}・{time}・{memo} を使い、各項目の前後や改行を自由に設定できます。',
          '置換ルールは完全一致する文字列を対象に上から順番に適用し、{match} で一致した文字列を再利用できます。',
          '左側の入力例は編集可能で、右側の変更がサマリープレビューへすぐ反映されます。',
          '新規作成はサマリーと設定のどちらからでも行えます。名前変更・編集・削除は設定から行います。',
        ],
      ),
      _GuideSection(
        title: 'ショートカットを使う',
        summary: 'SplitLog を開かずに主要操作を実行',
        details: [
          '${shortcutPrefix}S: Split / ${shortcutPrefix}X: 停止 / ${shortcutPrefix}R: 再開',
          '${shortcutPrefix}V: 表示切替 / ${shortcutPrefix}M: 選択中の Split メモを開く',
          '${shortcutPrefix}1...9: 指定位置を選択 / ${shortcutPrefix}0: 最新を選択 / $shortcutPrefix↑↓: 選択位置を移動',
          'グローバルショートカットは、設定からまとめてオン・オフできます。',
        ],
      ),
      _GuideSection(
        title: '表示とアプリ動作を整える',
        summary: 'テーマ・リング周期・初期モード・ロック',
        details: [
          '設定からテーマカラー、モノクロ表示、リング周期、新規セッションの初期配分モードを変更できます。',
          '円グラフ左上の小さい表示からもリング周期の設定を開けます。',
          '南京錠をオンにすると SplitLog を前面に保ち、ほかの場所をクリックしても閉じなくなります。オフの場合は外側のクリックで閉じます。',
          'ウィンドウを閉じてもアプリは常駐します。完全に終了する場合は、設定の「SplitLogを終了」を使います。',
          'ヘッダーの「?」または設定の案内から、操作説明とお問い合わせを開けます。',
        ],
      ),
      _GuideSection(
        title: 'データを移行・管理する',
        summary: 'ローカル保存・旧版インポート・初期化',
        details: [
          'セッションと設定はこの端末内に保存され、ほかの端末とは自動同期されません。',
          isWindows
              ? '旧macOS版のデータは、設定から sessions.json を選んで手動で取り込めます。'
              : '旧macOS版のデータは起動時に自動検知して確認後に取り込むか、設定から sessions.json を選んで手動で取り込めます。',
          '設定のストレージ項目から、セッション情報または Split データだけを削除できます。',
          '設定だけのリセットと全データの初期化も選べます。削除や初期化は確認後に実行されます。',
        ],
      ),
    ];
  }

  int? _expandedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return _ModalSurface(
      colors: widget.colors,
      width: 408,
      padding: const EdgeInsets.all(16),
      borderRadius: 18,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '操作説明',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '項目をクリックすると、詳しい説明が開きます。',
                      style: TextStyle(
                        fontSize: 11,
                        color: widget.colors.secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
              _OverlayCloseButton(
                colors: widget.colors,
                size: 26,
                onPressed: widget.onClose,
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 272,
            child: ListView.separated(
              key: const ValueKey<String>('guide-sections-scroll-view'),
              padding: EdgeInsets.zero,
              itemCount: _sections.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final section = _sections[index];
                final isExpanded = _expandedIndex == index;
                return AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: isExpanded
                          ? Colors.black.withValues(alpha: 0.035)
                          : Colors.transparent,
                      border: Border.all(
                        color: isExpanded
                            ? Colors.black.withValues(alpha: 0.08)
                            : Colors.transparent,
                      ),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () {
                            setState(() {
                              _expandedIndex = isExpanded ? null : index;
                            });
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.78),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        section.title,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        section.summary,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: widget.colors.secondaryText,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  isExpanded
                                      ? Icons.keyboard_arrow_up
                                      : Icons.keyboard_arrow_down,
                                  size: 16,
                                  color: widget.colors.secondaryText,
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (isExpanded) ...[
                          const SizedBox(height: 6),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.62),
                              border: Border.all(color: widget.colors.border),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final detail in section.details)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 7),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 6,
                                          ),
                                          child: Container(
                                            width: 5,
                                            height: 5,
                                            decoration: BoxDecoration(
                                              color: widget.colors.accent,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            detail,
                                            style: const TextStyle(
                                              fontSize: 13,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GuideSection {
  const _GuideSection({
    required this.title,
    required this.summary,
    required this.details,
  });

  final String title;
  final String summary;
  final List<String> details;
}

class _ContactOverlay extends StatelessWidget {
  const _ContactOverlay({
    required this.colors,
    required this.onClose,
    required this.onOpenMail,
  });

  final _DesktopPreviewColors colors;
  final VoidCallback onClose;
  final VoidCallback onOpenMail;

  @override
  Widget build(BuildContext context) {
    return _ModalSurface(
      colors: colors,
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'お問い合わせ',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Text(
            '不具合報告や相談用のメール作成画面を開きます。',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _CompactDialogButton(
                colors: colors,
                label: '閉じる',
                onPressed: onClose,
              ),
              const SizedBox(width: 8),
              _CompactDialogButton(
                colors: colors,
                label: 'メールを開く',
                onPressed: onOpenMail,
                prominent: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModalSurface extends StatelessWidget {
  const _ModalSurface({
    required this.colors,
    required this.width,
    required this.child,
    this.height,
    this.padding = const EdgeInsets.all(14),
    this.borderRadius = 12,
  });

  final _DesktopPreviewColors colors;
  final double width;
  final double? height;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.surface,
      elevation: 18,
      shadowColor: Colors.black.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(borderRadius),
      child: Container(
        width: width,
        height: height,
        padding: padding,
        decoration: BoxDecoration(
          border: Border.all(color: colors.border),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: child,
      ),
    );
  }
}

class _CompactDialogButton extends StatelessWidget {
  const _CompactDialogButton({
    super.key,
    required this.colors,
    required this.label,
    required this.onPressed,
    this.prominent = false,
    this.destructive = false,
  });

  final _DesktopPreviewColors colors;
  final String label;
  final VoidCallback onPressed;
  final bool prominent;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final background = prominent
        ? destructive
              ? const Color(0xFFC94848)
              : colors.accent
        : colors.buttonBackground;
    final foreground = prominent ? Colors.white : colors.accent;
    final border = prominent ? background : colors.buttonBorder;

    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: onPressed,
      child: Container(
        height: 26,
        constraints: const BoxConstraints(minWidth: 58),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: foreground,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _SummaryCopyButton extends StatelessWidget {
  const _SummaryCopyButton({required this.colors, required this.onPressed});

  final _DesktopPreviewColors colors;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'コピー',
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onPressed,
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: 0.12),
            border: Border.all(color: colors.accent.withValues(alpha: 0.18)),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.copy, size: 12, color: colors.accent),
        ),
      ),
    );
  }
}

class _OverlayCloseButton extends StatelessWidget {
  const _OverlayCloseButton({
    required this.colors,
    required this.onPressed,
    this.size = 24,
  });

  final _DesktopPreviewColors colors;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '閉じる',
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onPressed,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: colors.headerControl,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.close, size: 11, color: colors.accent),
        ),
      ),
    );
  }
}

class _ToastBanner extends StatelessWidget {
  const _ToastBanner({required this.message, required this.style});

  final String message;
  final _ToastStyle style;

  @override
  Widget build(BuildContext context) {
    final isError = style == _ToastStyle.error;
    final foreground = isError
        ? const Color(0xFF801414)
        : Colors.black.withValues(alpha: 0.90);
    final background = isError
        ? const Color(0xFFFFEBEB)
        : Colors.white.withValues(alpha: 0.92);
    final border = isError
        ? const Color(0xFFD95959)
        : Colors.black.withValues(alpha: 0.15);

    return Material(
      color: Colors.transparent,
      elevation: 4,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: background,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          message,
          style: TextStyle(
            color: foreground,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({
    required this.icon,
    required this.tooltip,
    required this.colors,
    required this.onPressed,
    this.size = 24,
    this.iconSize = 14,
    this.filled = false,
  });

  final IconData icon;
  final String tooltip;
  final _DesktopPreviewColors colors;
  final VoidCallback onPressed;
  final double size;
  final double iconSize;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: filled ? colors.accent : colors.headerControl,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              size: iconSize,
              color: filled ? Colors.white : colors.primaryText,
            ),
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      height: 3,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _TextActionButton extends StatelessWidget {
  const _TextActionButton({
    required this.colors,
    required this.label,
    required this.onPressed,
    this.prominent = false,
    this.enabled = true,
  });

  final _DesktopPreviewColors colors;
  final String label;
  final VoidCallback onPressed;
  final bool prominent;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final background = prominent
        ? colors.accent
        : enabled
        ? colors.buttonBackground
        : colors.disabledButtonBackground;
    final border = prominent
        ? colors.accent
        : enabled
        ? colors.buttonBorder
        : colors.disabledButtonBorder;
    final foreground = prominent
        ? Colors.white
        : enabled
        ? colors.primaryText
        : colors.disabledText;

    return Tooltip(
      message: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: enabled ? onPressed : null,
        child: Container(
          height: 24,
          constraints: BoxConstraints(minWidth: label == 'Split' ? 52 : 48),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: background,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 12,
              height: defaultTargetPlatform == TargetPlatform.windows
                  ? 1
                  : null,
              fontWeight: prominent ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _UtilityButton extends StatelessWidget {
  const _UtilityButton({
    required this.colors,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final _DesktopPreviewColors colors;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.buttonBackground,
            border: Border.all(color: colors.buttonBorder),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 15, color: colors.utility),
        ),
      ),
    );
  }
}

class _SmallPill extends StatelessWidget {
  const _SmallPill({
    required this.colors,
    required this.label,
    required this.tooltip,
  });

  final _DesktopPreviewColors colors;
  final String label;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.accent.withValues(alpha: 0.16),
          border: Border.all(color: colors.accent.withValues(alpha: 0.45)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: colors.accent,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 1),
            Icon(Icons.arrow_drop_down, size: 11, color: colors.accent),
          ],
        ),
      ),
    );
  }
}

class _SummaryTimeFormatMenu extends StatelessWidget {
  const _SummaryTimeFormatMenu({
    required this.colors,
    required this.selectedFormat,
    required this.previewLabel,
    required this.onSelected,
    this.compact = false,
  });

  final _DesktopPreviewColors colors;
  final _SummaryTimeFormat selectedFormat;
  final String previewLabel;
  final ValueChanged<_SummaryTimeFormat> onSelected;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_SummaryTimeFormat>(
      key: ValueKey<String>(
        compact
            ? 'summary-time-format-menu'
            : 'settings-summary-time-format-menu',
      ),
      tooltip: '時間表示形式を選択',
      initialValue: selectedFormat,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final format in _summaryTimeFormatOptions)
          PopupMenuItem<_SummaryTimeFormat>(
            value: format,
            child: Text(
              format.optionLabel,
              style: const TextStyle(fontSize: 12),
            ),
          ),
      ],
      child: compact
          ? _SmallPill(
              colors: colors,
              label: previewLabel,
              tooltip: '時間表示形式を選択',
            )
          : _MenuValuePill(colors: colors, label: previewLabel),
    );
  }
}

class _SummaryFormatMenu extends StatelessWidget {
  const _SummaryFormatMenu({
    required this.colors,
    required this.selectedFormatId,
    required this.customFormats,
    required this.onSelected,
    required this.onAdd,
  });

  final _DesktopPreviewColors colors;
  final String selectedFormatId;
  final List<SummaryFormatDefinition> customFormats;
  final ValueChanged<String> onSelected;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final selected = resolveSummaryFormat(selectedFormatId, customFormats);
    return PopupMenuButton<String>(
      key: const ValueKey<String>('settings-summary-format-menu'),
      tooltip: 'サマリー表示フォーマット',
      initialValue: selected.id,
      onSelected: (value) {
        if (value == '_add') {
          onAdd();
        } else {
          onSelected(value);
        }
      },
      itemBuilder: (context) =>
          _summaryFormatMenuItems(customFormats, includeAdd: true),
      child: _SummaryFormatMenuSurface(colors: colors, label: selected.name),
    );
  }
}

class _SummaryFormatPill extends StatelessWidget {
  const _SummaryFormatPill({
    required this.colors,
    required this.selectedFormatId,
    required this.customFormats,
    required this.onSelected,
    required this.onAdd,
  });

  final _DesktopPreviewColors colors;
  final String selectedFormatId;
  final List<SummaryFormatDefinition> customFormats;
  final ValueChanged<String> onSelected;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final selected = resolveSummaryFormat(selectedFormatId, customFormats);
    return PopupMenuButton<String>(
      key: const ValueKey<String>('summary-format-menu'),
      tooltip: 'サマリー表示フォーマット',
      initialValue: selected.id,
      onSelected: (value) {
        if (value == '_add') {
          onAdd();
        } else {
          onSelected(value);
        }
      },
      itemBuilder: (context) =>
          _summaryFormatMenuItems(customFormats, includeAdd: true),
      child: Container(
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.accent.withValues(alpha: 0.16),
          border: Border.all(color: colors.accent.withValues(alpha: 0.45)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              selected.name,
              style: TextStyle(
                color: colors.accent,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 12, color: colors.accent),
          ],
        ),
      ),
    );
  }
}

List<PopupMenuEntry<String>> _summaryFormatMenuItems(
  List<SummaryFormatDefinition> customFormats, {
  bool includeAdd = false,
}) {
  return [
    for (final format in builtInSummaryFormats)
      PopupMenuItem<String>(
        value: format.id,
        height: 30,
        child: Text(
          format.id == templateSummaryFormatId ? 'テンプレート' : format.name,
          style: const TextStyle(fontSize: 12),
        ),
      ),
    if (customFormats.isNotEmpty) const PopupMenuDivider(height: 8),
    for (final format in customFormats)
      PopupMenuItem<String>(
        value: format.id,
        height: 30,
        child: Text(
          format.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
      ),
    if (includeAdd) const PopupMenuDivider(height: 8),
    if (includeAdd)
      const PopupMenuItem<String>(
        value: '_add',
        height: 30,
        child: Row(
          children: [
            Icon(Icons.add, size: 14),
            SizedBox(width: 6),
            Text('カスタムを追加', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
  ];
}

class _SummaryFormatMenuSurface extends StatelessWidget {
  const _SummaryFormatMenuSurface({required this.colors, required this.label});

  final _DesktopPreviewColors colors;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      constraints: const BoxConstraints(minWidth: 76, maxWidth: 112),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.buttonBackground,
        border: Border.all(color: colors.buttonBorder),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
          ),
          const SizedBox(width: 3),
          Icon(Icons.arrow_drop_down, size: 13, color: colors.secondaryText),
        ],
      ),
    );
  }
}

class _SummaryFormatEditButton extends StatelessWidget {
  const _SummaryFormatEditButton({
    required this.colors,
    required this.selectedFormat,
    required this.onAdd,
    required this.onEdit,
  });

  final _DesktopPreviewColors colors;
  final SummaryFormatDefinition selectedFormat;
  final VoidCallback onAdd;
  final ValueChanged<SummaryFormatDefinition> onEdit;

  @override
  Widget build(BuildContext context) {
    final isBuiltIn = selectedFormat.isBuiltIn;
    return _MiniIconButton(
      colors: colors,
      icon: isBuiltIn ? Icons.add : Icons.edit_outlined,
      tooltip: isBuiltIn ? 'カスタムを追加' : 'カスタムを編集',
      onPressed: isBuiltIn ? onAdd : () => onEdit(selectedFormat),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.colors, required this.label});

  final _DesktopPreviewColors colors;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(fontSize: 11, color: colors.secondaryText),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.colors,
    required this.title,
    required this.trailing,
  });

  final _DesktopPreviewColors colors;
  final String title;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(fontSize: 13, color: colors.primaryText),
          ),
          const Spacer(),
          trailing,
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.colors,
    required this.title,
    required this.icon,
    this.onPressed,
    this.destructive = false,
  });

  final _DesktopPreviewColors colors;
  final String title;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final iconColor = destructive ? const Color(0xFFC94848) : colors.utility;

    return SizedBox(
      height: 28,
      child: Row(
        children: [
          Text(title, style: const TextStyle(fontSize: 13)),
          const Spacer(),
          Tooltip(
            message: title,
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: onPressed ?? () {},
              child: Container(
                width: 28,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.buttonBackground,
                  border: Border.all(color: colors.buttonBorder),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(icon, size: 15, color: iconColor),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineStepperValue extends StatelessWidget {
  const _InlineStepperValue({
    required this.value,
    required this.onDecrease,
    required this.onIncrease,
  });

  final String value;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: const TextStyle(fontSize: 13)),
        const SizedBox(width: 6),
        Container(
          width: 20,
          height: 28,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.08),
            border: Border.all(color: Colors.black.withValues(alpha: 0.10)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onIncrease,
                  child: const Center(
                    child: Icon(Icons.keyboard_arrow_up, size: 14),
                  ),
                ),
              ),
              Container(height: 1, color: Colors.black.withValues(alpha: 0.10)),
              Expanded(
                child: InkWell(
                  onTap: onDecrease,
                  child: const Center(
                    child: Icon(Icons.keyboard_arrow_down, size: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MenuValuePill extends StatelessWidget {
  const _MenuValuePill({required this.colors, required this.label});

  final _DesktopPreviewColors colors;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.buttonBackground,
        border: Border.all(color: colors.buttonBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          Icon(Icons.arrow_drop_down, size: 14, color: colors.secondaryText),
        ],
      ),
    );
  }
}

class _HelpCard extends StatelessWidget {
  const _HelpCard({
    required this.colors,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onPressed,
  });

  final _DesktopPreviewColors colors;
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.70),
          border: Border.all(color: colors.accent.withValues(alpha: 0.18)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: colors.accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 15, color: colors.accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.2,
                      color: colors.secondaryText,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Icon(
                Icons.chevron_right,
                size: 15,
                color: colors.secondaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelineRingPainter extends CustomPainter {
  const _TimelineRingPainter({
    required this.colors,
    required this.laps,
    required this.lapSeconds,
    required this.totalSeconds,
    required this.ringHoursPerCycle,
  });

  final _DesktopPreviewColors colors;
  final List<WorkLap> laps;
  final Map<String, int> lapSeconds;
  final int totalSeconds;
  final int ringHoursPerCycle;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final cycleSeconds = math.max(1, ringHoursPerCycle) * 60 * 60;
    const innerLineWidth = 30.0;
    const outerLineWidth = 30.0;
    const ringDiameterInset = 16.0;
    const edgeInset = 4.0;
    const perimeterBorderLineWidth = 2.0;
    const segmentBoundaryLineWidth = 1.0;
    const contactBorderOutwardOffset = 3.0;
    final showOuter = totalSeconds >= cycleSeconds;
    final side = math.max(0.0, math.min(size.width, size.height) - edgeInset);
    final ringSide = math.max(0.0, side - ringDiameterInset);
    final innerSide = math.max(0.0, ringSide - 56);

    final ranges = <_LapRange>[];
    var cursor = 0;
    for (final lap in laps) {
      final seconds = lapSeconds[lap.id] ?? lap.accumulatedSeconds;
      ranges.add(_LapRange(lap: lap, start: cursor, end: cursor + seconds));
      cursor += seconds;
    }

    if (!showOuter) {
      _drawTrack(canvas, center, innerSide, innerLineWidth);
      _drawSlices(
        canvas,
        center,
        innerSide,
        innerLineWidth,
        segmentBoundaryLineWidth,
        0,
        cycleSeconds,
        ranges,
      );
      _drawOuterPerimeterBorder(
        canvas,
        center,
        innerSide,
        innerLineWidth,
        perimeterBorderLineWidth,
      );
      _drawInnerPerimeterBorder(
        canvas,
        center,
        innerSide,
        innerLineWidth,
        0,
        perimeterBorderLineWidth,
      );
    } else {
      final currentStart = (totalSeconds ~/ cycleSeconds) * cycleSeconds;
      _drawTrack(canvas, center, ringSide, outerLineWidth);
      _drawSlices(
        canvas,
        center,
        ringSide,
        outerLineWidth,
        segmentBoundaryLineWidth,
        currentStart,
        currentStart + cycleSeconds,
        ranges,
      );
      _drawTrack(canvas, center, innerSide, innerLineWidth);
      _drawSlices(
        canvas,
        center,
        innerSide,
        innerLineWidth,
        segmentBoundaryLineWidth,
        currentStart - cycleSeconds,
        currentStart,
        ranges,
      );
      _drawOuterPerimeterBorder(
        canvas,
        center,
        ringSide,
        outerLineWidth,
        perimeterBorderLineWidth,
      );
      _drawInnerPerimeterBorder(
        canvas,
        center,
        ringSide,
        outerLineWidth,
        contactBorderOutwardOffset,
        segmentBoundaryLineWidth,
      );
      _drawInnerPerimeterBorder(
        canvas,
        center,
        innerSide,
        innerLineWidth,
        0,
        perimeterBorderLineWidth,
      );
    }
  }

  void _drawTrack(
    Canvas canvas,
    Offset center,
    double frameSide,
    double width,
  ) {
    final paint = Paint()
      ..color = colors.track
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    canvas.drawCircle(center, frameSide / 2, paint);
  }

  void _drawSlices(
    Canvas canvas,
    Offset center,
    double frameSide,
    double width,
    double boundaryWidth,
    int windowStart,
    int windowEnd,
    List<_LapRange> ranges,
  ) {
    final rect = Rect.fromCircle(center: center, radius: frameSide / 2);
    final window = windowEnd - windowStart;
    final ratios = <_TimelineSliceRatio>[];

    for (final range in ranges) {
      final start = math.max(range.start, windowStart);
      final end = math.min(range.end, windowEnd);
      if (end <= start) {
        continue;
      }
      final startRatio = (start - windowStart) / window;
      final endRatio = (end - windowStart) / window;
      final paint = Paint()
        ..color = colors.lapColor(range.lap.index)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(
        rect,
        (-math.pi / 2) + (math.pi * 2 * startRatio),
        math.pi * 2 * (endRatio - startRatio),
        false,
        paint,
      );
      ratios.add(_TimelineSliceRatio(start: startRatio, end: endRatio));
    }

    for (final ratio in _boundaryRatios(ratios)) {
      _drawSliceSeparator(
        canvas,
        center,
        frameSide,
        width,
        boundaryWidth,
        ratio,
      );
    }
  }

  void _drawOuterPerimeterBorder(
    Canvas canvas,
    Offset center,
    double frameSide,
    double ringLineWidth,
    double lineWidth,
  ) {
    final paint = Paint()
      ..color = colors.ringBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(
      center,
      (frameSide + ringLineWidth + lineWidth) / 2,
      paint,
    );
  }

  void _drawInnerPerimeterBorder(
    Canvas canvas,
    Offset center,
    double frameSide,
    double ringLineWidth,
    double outwardOffset,
    double lineWidth,
  ) {
    final paint = Paint()
      ..color = colors.ringBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(
      center,
      math.max(0, frameSide - ringLineWidth - lineWidth + (outwardOffset * 2)) /
          2,
      paint,
    );
  }

  void _drawSliceSeparator(
    Canvas canvas,
    Offset center,
    double frameSide,
    double width,
    double boundaryWidth,
    double ratio,
  ) {
    final angle = (-math.pi / 2) + (math.pi * 2 * ratio);
    final direction = Offset(math.cos(angle), math.sin(angle));
    final paint = Paint()
      ..color = colors.ringBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = boundaryWidth
      ..strokeCap = StrokeCap.round;
    final radius = frameSide / 2;
    canvas.drawLine(
      center + (direction * (radius - (width / 2))),
      center + (direction * (radius + (width / 2))),
      paint,
    );
  }

  List<double> _boundaryRatios(List<_TimelineSliceRatio> slices) {
    if (slices.length <= 1) {
      return const [];
    }

    final sorted = [...slices]
      ..sort((lhs, rhs) {
        if (lhs.start == rhs.start) {
          return lhs.end.compareTo(rhs.end);
        }
        return lhs.start.compareTo(rhs.start);
      });

    const epsilon = 0.0005;
    final boundaries = <double>[];
    for (var index = 1; index < sorted.length; index += 1) {
      final previous = sorted[index - 1];
      final current = sorted[index];
      if ((previous.end - current.start).abs() <= epsilon) {
        boundaries.add(current.start);
      }
    }
    return boundaries;
  }

  @override
  bool shouldRepaint(covariant _TimelineRingPainter oldDelegate) {
    return oldDelegate.colors != colors ||
        oldDelegate.totalSeconds != totalSeconds ||
        oldDelegate.ringHoursPerCycle != ringHoursPerCycle ||
        oldDelegate.lapSeconds != lapSeconds ||
        oldDelegate.laps != laps;
  }
}

class _DesktopPreviewColors {
  const _DesktopPreviewColors({required this.isMonochrome});

  final bool isMonochrome;

  Color get accent =>
      isMonochrome ? const Color(0xFF404040) : const Color(0xFF0A84FF);

  Color get surface =>
      isMonochrome ? const Color(0xFFF2F2F2) : const Color(0xFFE8ECEC);

  Color get section => isMonochrome
      ? Colors.black.withValues(alpha: 0.06)
      : Colors.white.withValues(alpha: 0.55);

  Color get lapCard => isMonochrome
      ? Colors.black.withValues(alpha: 0.05)
      : Colors.white.withValues(alpha: 0.52);

  Color get inlineEditorBackground => isMonochrome
      ? Colors.black.withValues(alpha: 0.14)
      : Colors.white.withValues(alpha: 0.90);

  Color get memoFieldBackground => isMonochrome
      ? Colors.white.withValues(alpha: 0.76)
      : Colors.white.withValues(alpha: 0.70);

  Color get panelSurface =>
      isMonochrome ? const Color(0xFFF2F2F2) : const Color(0xFFF0F2F2);

  Color get menuGroupBackground => isMonochrome
      ? Colors.black.withValues(alpha: 0.04)
      : Colors.white.withValues(alpha: 0.42);

  Color get menuRowBackground => isMonochrome
      ? Colors.black.withValues(alpha: 0.12)
      : Colors.black.withValues(alpha: 0.07);

  Color get headerControl => isMonochrome
      ? Colors.black.withValues(alpha: 0.14)
      : Colors.black.withValues(alpha: 0.08);

  Color get overflowButtonBackground => isMonochrome
      ? Colors.black.withValues(alpha: 0.16)
      : Colors.black.withValues(alpha: 0.10);

  Color get selectedChip => isMonochrome
      ? Colors.black.withValues(alpha: 0.20)
      : Colors.black.withValues(alpha: 0.14);

  Color get border => isMonochrome
      ? Colors.black.withValues(alpha: 0.24)
      : Colors.black.withValues(alpha: 0.13);

  Color get strongBorder => isMonochrome
      ? Colors.black.withValues(alpha: 0.38)
      : Colors.black.withValues(alpha: 0.28);

  Color get primaryText => const Color(0xFF101318);

  Color get secondaryText => Colors.black.withValues(alpha: 0.58);

  Color get softText => Colors.black.withValues(alpha: 0.24);

  Color get utility => const Color(0xFF3C3C3C);

  Color get buttonBackground => Colors.white.withValues(alpha: 0.42);

  Color get buttonBorder => Colors.black.withValues(alpha: 0.18);

  Color get disabledButtonBackground => Colors.white.withValues(alpha: 0.22);

  Color get disabledButtonBorder => Colors.white.withValues(alpha: 0.18);

  Color get disabledText => isMonochrome
      ? Colors.black.withValues(alpha: 0.38)
      : const Color(0xFFBFD9FF);

  Color get track => isMonochrome
      ? const Color(0xFFEDEDED)
      : Colors.black.withValues(alpha: 0.08);

  Color get ringBorder =>
      isMonochrome ? Colors.black.withValues(alpha: 0.82) : Colors.white;

  Color lapColor(int index) {
    final zeroBased = math.max(0, index - 1);
    if (isMonochrome) {
      const values = [0.18, 0.27, 0.36, 0.45, 0.54, 0.63, 0.72, 0.81];
      final value = values[zeroBased % values.length];
      return Color.fromRGBO(
        (value * 255).round(),
        (value * 255).round(),
        (value * 255).round(),
        1,
      );
    }

    const colors = [
      Color(0xFFFF0000),
      Color(0xFFFF4000),
      Color(0xFFFF8000),
      Color(0xFFFFC000),
      Color(0xFFFFFF00),
      Color(0xFFC0FF00),
      Color(0xFF80FF00),
      Color(0xFF40FF00),
      Color(0xFF00FF00),
      Color(0xFF00FF40),
      Color(0xFF00FF80),
      Color(0xFF00FFC0),
      Color(0xFF00FFFF),
      Color(0xFF00C0FF),
      Color(0xFF0080FF),
      Color(0xFF0040FF),
      Color(0xFF0000FF),
      Color(0xFF4000FF),
      Color(0xFF8000FF),
      Color(0xFFC000FF),
      Color(0xFFFF00FF),
      Color(0xFFFF00C0),
      Color(0xFFFF0080),
      Color(0xFFFF0040),
    ];
    return colors[zeroBased % colors.length];
  }

  ButtonStyle filledButtonStyle({bool destructive = false}) {
    final background = destructive
        ? (isMonochrome ? const Color(0xFF3A3A3A) : const Color(0xFFC94848))
        : accent;
    return FilledButton.styleFrom(
      backgroundColor: background,
      foregroundColor: Colors.white,
      disabledBackgroundColor: disabledButtonBackground,
      disabledForegroundColor: disabledText,
    );
  }

  ButtonStyle compactFilledButtonStyle() {
    return FilledButton.styleFrom(
      backgroundColor: accent,
      foregroundColor: Colors.white,
      minimumSize: const Size(60, 26),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
    );
  }

  ButtonStyle outlinedButtonStyle() {
    return OutlinedButton.styleFrom(
      foregroundColor: isMonochrome ? primaryText : accent,
      side: BorderSide(color: isMonochrome ? buttonBorder : accent),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _DesktopPreviewColors && other.isMonochrome == isMonochrome;
  }

  @override
  int get hashCode => isMonochrome.hashCode;
}

class _SessionSummary {
  const _SessionSummary({
    required this.text,
    required this.headerText,
    required this.timeFormatLabel,
  });

  final String text;
  final String headerText;
  final String timeFormatLabel;
}

_SessionSummary _buildSessionSummary({
  required StopwatchController stopwatch,
  required Map<String, int> lapSeconds,
  required int totalSeconds,
  required SummaryFormatDefinition format,
  required _SummaryTimeFormat timeFormat,
}) {
  final lines = <String>[];
  if (stopwatch.laps.isEmpty) {
    lines.add('Splitはまだありません');
  } else {
    for (final lap in stopwatch.laps) {
      final elapsedSeconds = lapSeconds[lap.id] ?? lap.accumulatedSeconds;
      final entry = renderSummaryEntry(
        format: format,
        title: lap.label,
        time: _formatSummaryDuration(elapsedSeconds, timeFormat),
        memo: lap.memo,
      );
      if (entry.isNotEmpty) {
        lines.add(entry);
      }
    }
  }

  final sessionTitle = stopwatch.session?.title ?? '';
  return _SessionSummary(
    text: lines.join('\n'),
    headerText:
        '$sessionTitle (${_formatSummaryDuration(totalSeconds, timeFormat)})',
    timeFormatLabel: _formatSummaryDuration(totalSeconds, timeFormat),
  );
}

String _formatSummaryDuration(int seconds, _SummaryTimeFormat format) {
  final safeSeconds = math.max(0, seconds);
  switch (format) {
    case _SummaryTimeFormat.decimalHours:
      return '${(safeSeconds / 3600).toStringAsFixed(1)}h';
    case _SummaryTimeFormat.decimalHoursPrecise:
      return '${(safeSeconds / 3600).toStringAsFixed(2)}h';
    case _SummaryTimeFormat.hourMinute:
      final totalMinutes = (safeSeconds + 30) ~/ 60;
      final hours = totalMinutes ~/ 60;
      final minutes = totalMinutes % 60;
      return '$hours時間$minutes分';
  }
}

StopwatchSnapshot _emptySessionSnapshot(
  DateTime now,
  String title, {
  SplitAccumulationMode splitMode = SplitAccumulationMode.checkbox,
}) {
  return StopwatchSnapshot(
    session: WorkSession(id: 'session-$title', title: title, startedAt: now),
    laps: const [],
    selectedLapId: null,
    activeLapIds: const {},
    splitAccumulationMode: splitMode,
    state: SessionState.idle,
    pauseStartedAt: null,
    lastDistributedWholeSeconds: 0,
    distributionCursor: 0,
    totalPausedSeconds: 0,
  );
}

String _dateTitle(DateTime date) {
  return '${date.year}/${date.month}/${date.day}';
}

String _nextSessionTitle(DateTime date, List<String> existingTitles) {
  final baseTitle = _dateTitle(date);
  if (!existingTitles.contains(baseTitle)) {
    return baseTitle;
  }

  var suffixIndex = 1;
  while (existingTitles.contains(
    '$baseTitle-${_sessionTitleSuffix(suffixIndex)}',
  )) {
    suffixIndex += 1;
  }
  return '$baseTitle-${_sessionTitleSuffix(suffixIndex)}';
}

String _sessionTitleSuffix(int index) {
  var value = math.max(1, index);
  final codeUnits = <int>[];
  while (value > 0) {
    final zeroBased = (value - 1) % 26;
    codeUnits.add(65 + zeroBased);
    value = (value - 1) ~/ 26;
  }
  return String.fromCharCodes(codeUnits.reversed);
}

String _singleLineLabel(String value) {
  return value.replaceAll(RegExp(r'[\r\n]+'), '').trim();
}

class _SingleLineTextFormatter extends TextInputFormatter {
  const _SingleLineTextFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = _singleLineLabel(newValue.text);
    if (text == newValue.text) {
      return newValue;
    }
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: math.min(text.length, newValue.selection.extentOffset),
      ),
    );
  }
}

class _LapRange {
  const _LapRange({required this.lap, required this.start, required this.end});

  final WorkLap lap;
  final int start;
  final int end;
}

class _TimelineSliceRatio {
  const _TimelineSliceRatio({required this.start, required this.end});

  final double start;
  final double end;
}

String _formatDuration(int totalSeconds) {
  final safeSeconds = math.max(0, totalSeconds);
  final hours = safeSeconds ~/ 3600;
  final minutes = (safeSeconds % 3600) ~/ 60;
  final seconds = safeSeconds % 60;
  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}
