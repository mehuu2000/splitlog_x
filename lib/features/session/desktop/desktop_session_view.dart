import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/session_models.dart';
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

enum _SummaryMemoFormat { bulleted, plain }

enum _SummaryTimeFormat { decimalHours, hourMinute }

_SummaryMemoFormat _summaryMemoFormatFromName(String value) {
  return _SummaryMemoFormat.values.firstWhere(
    (format) => format.name == value,
    orElse: () => _SummaryMemoFormat.bulleted,
  );
}

_SummaryTimeFormat _summaryTimeFormatFromName(String value) {
  return _SummaryTimeFormat.values.firstWhere(
    (format) => format.name == value,
    orElse: () => _SummaryTimeFormat.decimalHours,
  );
}

const _appPlatformChannel = MethodChannel('splitlog_x/app');

class DesktopSessionView extends StatefulWidget {
  const DesktopSessionView({super.key});

  @override
  State<DesktopSessionView> createState() => _DesktopSessionViewState();
}

class _DesktopSessionViewState extends State<DesktopSessionView> {
  _PreviewOverlay _overlay = _PreviewOverlay.none;
  bool _isLocked = false;
  bool _isMonochrome = false;
  final SessionStorageService _storage = SessionStorageService();
  late final List<StopwatchController> _stopwatches;
  int _selectedSessionIndex = 0;
  late DateTime _clock;
  Timer? _ticker;
  final TextEditingController _lapLabelController = TextEditingController();
  final FocusNode _lapLabelFocus = FocusNode();
  final ScrollController _lapLabelScrollController = ScrollController();
  String? _editingLapId;
  final TextEditingController _sessionTitleController = TextEditingController();
  final FocusNode _sessionTitleFocus = FocusNode();
  bool _isEditingSessionTitle = false;
  final TextEditingController _memoLabelController = TextEditingController();
  final TextEditingController _memoTextController = TextEditingController();
  String? _memoLapId;
  String _memoElapsedText = '00:00:00';
  int _ringHoursPerCycle = 4;
  SplitAccumulationMode _defaultSplitMode = SplitAccumulationMode.radio;
  _SummaryMemoFormat _summaryMemoFormat = _SummaryMemoFormat.bulleted;
  _SummaryTimeFormat _summaryTimeFormat = _SummaryTimeFormat.decimalHours;
  bool _shortcutsEnabled = true;

  StopwatchController get _stopwatch => _stopwatches[_selectedSessionIndex];

  @override
  void initState() {
    super.initState();
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
    _lapLabelFocus.removeListener(_handleLapLabelFocusChange);
    _sessionTitleFocus.removeListener(_handleSessionTitleFocusChange);
    _lapLabelController.dispose();
    _lapLabelFocus.dispose();
    _lapLabelScrollController.dispose();
    _sessionTitleController.dispose();
    _sessionTitleFocus.dispose();
    _memoLabelController.dispose();
    _memoTextController.dispose();
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
        setState(() {
          _restoreStorageSnapshot(snapshot);
        });
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

  void _restoreStorageSnapshot(SplitLogStorageSnapshot snapshot) {
    final restored = [
      for (final session in snapshot.sessions)
        StopwatchController(initialSnapshot: session),
    ];
    if (restored.isEmpty) {
      return;
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
    _summaryMemoFormat = _summaryMemoFormatFromName(
      snapshot.settings.summaryMemoFormat,
    );
    _summaryTimeFormat = _summaryTimeFormatFromName(
      snapshot.settings.summaryTimeFormat,
    );
    _shortcutsEnabled = snapshot.settings.shortcutsEnabled;
    unawaited(_setNativeShortcutsEnabled(_shortcutsEnabled));
    unawaited(_setNativePopoverLocked(_isLocked));
    _overlay = _PreviewOverlay.none;
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
        summaryMemoFormat: _summaryMemoFormat.name,
        summaryTimeFormat: _summaryTimeFormat.name,
        shortcutsEnabled: _shortcutsEnabled,
      ),
    );
  }

  void _persistState() {
    unawaited(_storage.save(_storageSnapshot()));
  }

  void _refresh({bool persist = false}) {
    setState(() {
      _clock = DateTime.now();
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

  void _deleteAllSessionData() {
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
  }

  void _deleteAllLapData() {
    final now = DateTime.now();
    setState(() {
      for (final stopwatch in _stopwatches) {
        stopwatch.reset(at: now);
      }
      _clock = now;
    });
    _persistState();
  }

  void _resetSettings() {
    setState(() {
      _isMonochrome = false;
      _ringHoursPerCycle = 4;
      _defaultSplitMode = SplitAccumulationMode.radio;
      _summaryMemoFormat = _SummaryMemoFormat.bulleted;
      _summaryTimeFormat = _SummaryTimeFormat.decimalHours;
      _shortcutsEnabled = true;
    });
    _persistState();
    unawaited(_setNativeShortcutsEnabled(_shortcutsEnabled));
  }

  void _initializeAllData() {
    _deleteAllSessionData();
    _resetSettings();
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

  void _setSummaryMemoFormat(_SummaryMemoFormat format) {
    setState(() {
      _summaryMemoFormat = format;
    });
    _persistState();
  }

  void _toggleSummaryMemoFormat() {
    _setSummaryMemoFormat(
      _summaryMemoFormat == _SummaryMemoFormat.bulleted
          ? _SummaryMemoFormat.plain
          : _SummaryMemoFormat.bulleted,
    );
  }

  void _setSummaryTimeFormat(_SummaryTimeFormat format) {
    setState(() {
      _summaryTimeFormat = format;
    });
    _persistState();
  }

  void _toggleSummaryTimeFormat() {
    _setSummaryTimeFormat(
      _summaryTimeFormat == _SummaryTimeFormat.decimalHours
          ? _SummaryTimeFormat.hourMinute
          : _SummaryTimeFormat.decimalHours,
    );
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
      _restoreStorageSnapshot(snapshot);
    });
    _persistState();
  }

  Future<void> _importLegacyDataFromFile() async {
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
      _restoreStorageSnapshot(snapshot);
    });
    _persistState();
  }

  Future<void> _openContactMail() async {
    await _appPlatformChannel.invokeMethod<void>('openContact');
  }

  Future<void> _quitApp() async {
    await _appPlatformChannel.invokeMethod<void>('quitApp');
  }

  Future<void> _setNativeShortcutsEnabled(bool enabled) async {
    try {
      await _appPlatformChannel.invokeMethod<void>('setShortcutsEnabled', {
        'enabled': enabled,
      });
    } on MissingPluginException {
      // Non-macOS targets do not need desktop global shortcuts.
    }
  }

  Future<void> _setNativePopoverLocked(bool locked) async {
    try {
      await _appPlatformChannel.invokeMethod<void>('setPopoverLocked', {
        'locked': locked,
      });
    } on MissingPluginException {
      // Non-macOS targets do not need popover locking.
    }
  }

  Future<Object?> _handlePlatformCall(MethodCall call) async {
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
    if (!_shortcutsEnabled || !mounted) {
      return;
    }
    final action = arguments['action'] as String?;
    final now = DateTime.now();
    var handled = false;

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
        }
      case 'moveLap':
        final offset = arguments['offset'];
        if (offset is int) {
          handled = _stopwatch.moveSelectedLapForShortcut(offset, at: now);
        }
    }

    if (handled) {
      _refresh(persist: true);
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
      memoFormat: _summaryMemoFormat,
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
                    onSummary: () => _show(_PreviewOverlay.summary),
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
              summaryMemoFormat: _summaryMemoFormat,
              summaryTimeFormat: _summaryTimeFormat,
              summary: summary,
              summaryTimePreviewLabel: summary.timeFormatLabel,
              shortcutsEnabled: _shortcutsEnabled,
              memoLabelController: _memoLabelController,
              memoTextController: _memoTextController,
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
              onSetSummaryMemoFormat: _setSummaryMemoFormat,
              onSetSummaryTimeFormat: _setSummaryTimeFormat,
              onToggleSummaryMemoFormat: _toggleSummaryMemoFormat,
              onToggleSummaryTimeFormat: _toggleSummaryTimeFormat,
              onSetShortcutsEnabled: _setShortcutsEnabled,
              onRequestLegacyImport: () => _show(_PreviewOverlay.legacyImport),
              onImportLegacyData: () => unawaited(_importLegacyData()),
              onImportLegacyDataFromFile: () =>
                  unawaited(_importLegacyDataFromFile()),
              onQuitApp: () => unawaited(_quitApp()),
              onDeleteSessionData: _deleteAllSessionData,
              onDeleteLapData: _deleteAllLapData,
              onResetSettings: _resetSettings,
              onInitializeAllData: _initializeAllData,
            ),
          ],
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
      height: 26,
      child: Row(
        children: [
          const Icon(Icons.timer_outlined, size: 18),
          const SizedBox(width: 5),
          const Text(
            'SplitLog',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          _CircleIconButton(
            icon: Icons.question_mark,
            tooltip: '使い方',
            colors: colors,
            size: 16,
            iconSize: 10,
            onPressed: onHelp,
          ),
          const SizedBox(width: 4),
          _CircleIconButton(
            icon: isLocked ? Icons.lock : Icons.lock_open,
            tooltip: isLocked ? 'Popoverロック中' : 'Popoverロック',
            colors: colors,
            size: 16,
            iconSize: 10,
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
            iconSize: 15,
            onPressed: onAddSession,
          ),
          const SizedBox(width: 8),
          _CircleIconButton(
            icon: Icons.settings_outlined,
            tooltip: '設定',
            colors: colors,
            size: 24,
            iconSize: 15,
            onPressed: onSettings,
          ),
        ],
      ),
    );
  }
}

class _SessionSelector extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Container(
      height: 25,
      decoration: BoxDecoration(
        border: Border.all(color: colors.strongBorder),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 220,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
              itemCount: sessions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 4),
              itemBuilder: (context, index) {
                final session = sessions[index];
                final isSelected = index == selectedIndex;
                return InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => onSelect(index),
                  child: Container(
                    width: 72,
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
          SizedBox(
            width: 24,
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
                      color: colors.headerControl,
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
            iconSize: 14,
            onPressed: onSummary,
          ),
          const SizedBox(width: 6),
          Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 8),
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
      height: 28,
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
        child: Icon(icon, size: 14, color: colors.primaryText),
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
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
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
                    Icon(Icons.sync, size: 10, color: colors.secondaryText),
                    const SizedBox(width: 2),
                    Text(
                      '${ringHoursPerCycle}h',
                      style: TextStyle(
                        fontSize: 10,
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

class _LapList extends StatelessWidget {
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
  final ValueChanged<WorkLap> onMemo;
  final ValueChanged<WorkLap> onBeginLapLabelEdit;
  final VoidCallback onCommitLapLabelEdit;
  final ValueChanged<String> onLeadingControl;

  @override
  Widget build(BuildContext context) {
    if (laps.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Splitはまだありません', style: TextStyle(color: colors.secondaryText)),
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
          child: ListView.separated(
            padding: EdgeInsets.zero,
            itemCount: laps.length,
            separatorBuilder: (_, _) => const SizedBox(height: 5),
            itemBuilder: (context, index) {
              return _LapRow(
                colors: colors,
                lap: laps[index],
                elapsed: _formatDuration(
                  lapSeconds[laps[index].id] ?? laps[index].accumulatedSeconds,
                ),
                splitMode: splitMode,
                selected: selectedLapId == laps[index].id,
                active: activeLapIds.contains(laps[index].id),
                isEditing: editingLapId == laps[index].id,
                editingController: editingLabelController,
                editingFocus: editingLabelFocus,
                editingScrollController: editingLabelScrollController,
                onMemo: () => onMemo(laps[index]),
                onBeginEdit: () => onBeginLapLabelEdit(laps[index]),
                onCommitEdit: onCommitLapLabelEdit,
                onLeadingControl: () => onLeadingControl(laps[index].id),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        Text(
          stateLabel,
          style: TextStyle(fontSize: 12, color: colors.secondaryText),
        ),
      ],
    );
  }
}

class _LapRow extends StatelessWidget {
  const _LapRow({
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
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
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
                  child: Icon(icon, size: 16, color: colors.primaryText),
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
                  width: 20,
                  height: 20,
                ),
                iconSize: 14,
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
          const SizedBox(height: 3),
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
    required this.summaryMemoFormat,
    required this.summaryTimeFormat,
    required this.summary,
    required this.summaryTimePreviewLabel,
    required this.shortcutsEnabled,
    required this.memoLabelController,
    required this.memoTextController,
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
    required this.onSetSummaryMemoFormat,
    required this.onSetSummaryTimeFormat,
    required this.onToggleSummaryMemoFormat,
    required this.onToggleSummaryTimeFormat,
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
  final _SummaryMemoFormat summaryMemoFormat;
  final _SummaryTimeFormat summaryTimeFormat;
  final _SessionSummary summary;
  final String summaryTimePreviewLabel;
  final bool shortcutsEnabled;
  final TextEditingController memoLabelController;
  final TextEditingController memoTextController;
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
  final ValueChanged<_SummaryMemoFormat> onSetSummaryMemoFormat;
  final ValueChanged<_SummaryTimeFormat> onSetSummaryTimeFormat;
  final VoidCallback onToggleSummaryMemoFormat;
  final VoidCallback onToggleSummaryTimeFormat;
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
            child: _SummaryOverlay(
              colors: colors,
              summary: summary,
              onToggleMemoFormat: onToggleSummaryMemoFormat,
              onToggleTimeFormat: onToggleSummaryTimeFormat,
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
              summaryMemoFormat: summaryMemoFormat,
              summaryTimeFormat: summaryTimeFormat,
              summaryTimePreviewLabel: summaryTimePreviewLabel,
              shortcutsEnabled: shortcutsEnabled,
              onSetTheme: onSetTheme,
              onSetRingHoursPerCycle: onSetRingHoursPerCycle,
              onSetDefaultSplitMode: onSetDefaultSplitMode,
              onSetSummaryMemoFormat: onSetSummaryMemoFormat,
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
  const _CenteredOverlay({required this.child, required this.onClose});

  final Widget child;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Stack(
        children: [
          GestureDetector(
            onTap: onClose,
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
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: selected ? colors.selectedChip : colors.menuRowBackground,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? colors.border : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                  color: colors.primaryText,
                ),
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 8),
              Icon(Icons.check, size: 13, color: colors.secondaryText),
            ],
          ],
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
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              style: TextStyle(fontSize: 13, color: colors.secondaryText),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (showCancel) ...[
                  OutlinedButton(
                    onPressed: onClose,
                    style: colors.outlinedButtonStyle(),
                    child: const Text('キャンセル'),
                  ),
                  const SizedBox(width: 8),
                ],
                FilledButton(
                  onPressed: onConfirm,
                  style: colors.filledButtonStyle(destructive: destructive),
                  child: Text(confirmTitle),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Splitメモ',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Text(
            'Split名',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: labelController,
            maxLines: 1,
            textInputAction: TextInputAction.done,
            inputFormatters: const [_SingleLineTextFormatter()],
            style: TextStyle(fontSize: 13, color: colors.primaryText),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: colors.memoFieldBackground,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
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
                borderSide: BorderSide(color: colors.accent),
              ),
              hintText: '作業内容',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                '経過時間',
                style: TextStyle(fontSize: 12, color: colors.secondaryText),
              ),
              const Spacer(),
              Text(
                elapsedText,
                style: const TextStyle(
                  fontSize: 13,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'メモ',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 118,
            child: TextField(
              controller: memoController,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: colors.primaryText,
              ),
              decoration: InputDecoration(
                filled: true,
                fillColor: colors.memoFieldBackground,
                contentPadding: const EdgeInsets.all(8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colors.accent),
                ),
                hintText: 'メモを入力',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton(
                onPressed: onClose,
                style: colors.filledButtonStyle(),
                child: const Text('閉じる'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryOverlay extends StatelessWidget {
  const _SummaryOverlay({
    required this.colors,
    required this.summary,
    required this.onToggleMemoFormat,
    required this.onToggleTimeFormat,
    required this.onClose,
  });

  final _DesktopPreviewColors colors;
  final _SessionSummary summary;
  final VoidCallback onToggleMemoFormat;
  final VoidCallback onToggleTimeFormat;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return _ModalSurface(
      colors: colors,
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text(
                'サマリー',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              _SmallPill(
                colors: colors,
                label: summary.memoFormatLabel,
                tooltip: 'メモ表示形式を切り替え',
                onPressed: onToggleMemoFormat,
              ),
              const SizedBox(width: 6),
              _SmallPill(
                colors: colors,
                label: summary.timeFormatLabel,
                tooltip: '時間表示形式を切り替え',
                onPressed: onToggleTimeFormat,
              ),
              const Spacer(),
              Text(
                summary.headerText,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: colors.secondaryText),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'コピー',
                iconSize: 16,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: summary.text));
                },
                icon: const Icon(Icons.copy),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            height: 218,
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.70),
              border: Border.all(color: colors.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                summary.text,
                style: const TextStyle(height: 1.45),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton(
                onPressed: onClose,
                style: colors.filledButtonStyle(),
                child: const Text('閉じる'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsOverlay extends StatelessWidget {
  const _SettingsOverlay({
    required this.colors,
    required this.isMonochrome,
    required this.onClose,
    required this.onOpenGuide,
    required this.onOpenContact,
    required this.ringHoursPerCycle,
    required this.defaultSplitMode,
    required this.summaryMemoFormat,
    required this.summaryTimeFormat,
    required this.summaryTimePreviewLabel,
    required this.shortcutsEnabled,
    required this.onSetTheme,
    required this.onSetRingHoursPerCycle,
    required this.onSetDefaultSplitMode,
    required this.onSetSummaryMemoFormat,
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
  final _SummaryMemoFormat summaryMemoFormat;
  final _SummaryTimeFormat summaryTimeFormat;
  final String summaryTimePreviewLabel;
  final bool shortcutsEnabled;
  final ValueChanged<bool> onSetTheme;
  final ValueChanged<int> onSetRingHoursPerCycle;
  final ValueChanged<SplitAccumulationMode> onSetDefaultSplitMode;
  final ValueChanged<_SummaryMemoFormat> onSetSummaryMemoFormat;
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

  @override
  Widget build(BuildContext context) {
    return _ModalSurface(
      colors: colors,
      width: 360,
      height: 360,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '設定',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _SettingsGroup(
                  colors: colors,
                  label: 'テーマカラー',
                  children: [
                    _ChoiceBar(
                      colors: colors,
                      selectedIndex: isMonochrome ? 1 : 0,
                      labels: const ['カラー', 'モノクロ'],
                      onTap: (index) => onSetTheme(index == 1),
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
                    _ChoiceBar(
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
                      title: 'メモ表示形式',
                      trailing: _MenuValuePill(
                        colors: colors,
                        label: summaryMemoFormat == _SummaryMemoFormat.bulleted
                            ? '- メモ'
                            : 'メモ',
                        onPressed: () => onSetSummaryMemoFormat(
                          summaryMemoFormat == _SummaryMemoFormat.bulleted
                              ? _SummaryMemoFormat.plain
                              : _SummaryMemoFormat.bulleted,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    _SettingsRow(
                      colors: colors,
                      title: '時間表示形式',
                      trailing: _MenuValuePill(
                        colors: colors,
                        label: summaryTimePreviewLabel,
                        onPressed: () => onSetSummaryTimeFormat(
                          summaryTimeFormat == _SummaryTimeFormat.decimalHours
                              ? _SummaryTimeFormat.hourMinute
                              : _SummaryTimeFormat.decimalHours,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _SettingsGroup(
                  colors: colors,
                  label: 'ショートカット',
                  children: [
                    _ChoiceBar(
                      colors: colors,
                      selectedIndex: shortcutsEnabled ? 0 : 1,
                      labels: const ['オン', 'オフ'],
                      onTap: (index) => onSetShortcutsEnabled(index == 0),
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
                      onPressed: onDeleteSessionData,
                    ),
                    const SizedBox(height: 6),
                    _ActionRow(
                      colors: colors,
                      title: 'Split情報',
                      icon: Icons.delete_outline,
                      destructive: true,
                      onPressed: onDeleteLapData,
                    ),
                    const SizedBox(height: 6),
                    _ActionRow(
                      colors: colors,
                      title: '設定のみ初期化',
                      icon: Icons.refresh,
                      onPressed: onResetSettings,
                    ),
                    const SizedBox(height: 6),
                    _ActionRow(
                      colors: colors,
                      title: '全データ初期化',
                      icon: Icons.warning_amber,
                      destructive: true,
                      onPressed: onInitializeAllData,
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
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton(
                onPressed: onClose,
                style: colors.filledButtonStyle(),
                child: const Text('閉じる'),
              ),
            ],
          ),
        ],
      ),
    );
  }
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
        const SizedBox(height: 7),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: colors.menuGroupBackground,
            border: Border.all(color: colors.border),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
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
      height: 28,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colors.headerControl,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          for (var index = 0; index < labels.length; index += 1)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => onTap(index),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: index == selectedIndex
                        ? colors.panelSurface
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text(
                '案内',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.close),
                iconSize: 16,
              ),
            ],
          ),
          const SizedBox(height: 10),
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
  static const _sections = [
    _GuideSection(
      title: '計測を進める',
      summary: '開始・Split・停止・再開の流れ',
      details: [
        'メインボタンで開始、停止、再開を切り替えます。',
        'Split ボタンで現在の作業区切りを閉じて、次の Split を作れます。',
        '停止中に再開すると、同じセッションを続きから計測します。',
      ],
    ),
    _GuideSection(
      title: 'セッションを切り替える',
      summary: '日ごとや作業単位で計測先を分ける',
      details: [
        '上部のセッション一覧から、今計測したいセッションへ切り替えられます。',
        'プラスボタンで新しいセッションを追加できます。',
        '不要なセッションは削除、現在の内容だけリセットも可能です。',
      ],
    ),
    _GuideSection(
      title: 'Split を選ぶ',
      summary: 'ラジオ配分とチェック配分を切り替える',
      details: [
        'ラジオ配分では、選択中の Split へ時間が入ります。',
        'チェック配分では、チェックが付いた Split 群へ時間を分配できます。',
        'モード切替はサマリーボタン左のアイコンから行えます。',
      ],
    ),
    _GuideSection(
      title: 'メモとサマリーを使う',
      summary: 'Split ごとのメモと全体サマリーを確認',
      details: [
        '各 Split のメモアイコンから内容を記録できます。',
        'サマリーボタンで、セッション全体の一覧テキストを確認できます。',
        'サマリーはコピーできるので、日報や振り返りへ流用しやすいです。',
        'お問い合わせは案内や設定から開けて、そのままメール送信画面へ進めます。',
      ],
    ),
    _GuideSection(
      title: 'ショートカットを使う',
      summary: 'Popover を開かずに主要操作を実行',
      details: [
        '⌘⌃S: Split / ⌘⌃X: 停止 / ⌘⌃R: 再開',
        '⌘⌃V: Popover の表示切替 / ⌘⌃M: 現在選択中 Split のメモを開く',
        '⌘⌃1...9 / 0 / ↑↓ で Split 選択や移動も行えます。',
      ],
    ),
    _GuideSection(
      title: '表示や初期値を整える',
      summary: 'テーマ、リング周期、初期モード、ロックなどの調整',
      details: [
        '設定からテーマカラーやリング周期を変更できます。',
        '新規セッションのデフォルト配分モードも設定できます。',
        '円グラフ左上の小さい表示からもリング周期の設定を開けます。',
        'タイトル右の南京錠アイコンをオンにすると、Popover 外をクリックしても閉じなくなります。',
        'サマリーの表示形式やストレージ初期化もここから行います。',
      ],
    ),
  ];

  int? _expandedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return _ModalSurface(
      colors: widget.colors,
      width: 408,
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
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'SplitLog でできることを順番に確認できます。',
                      style: TextStyle(
                        fontSize: 12,
                        color: widget.colors.secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: widget.onClose,
                icon: const Icon(Icons.close),
                iconSize: 16,
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 278,
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: _sections.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final section = _sections[index];
                final isExpanded = _expandedIndex == index;
                return Column(
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
                          border: Border.all(color: widget.colors.border),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    section.title,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    section.summary,
                                    style: TextStyle(
                                      fontSize: 12,
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
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
                                        style: const TextStyle(fontSize: 13),
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
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Text(
            '不具合報告や相談用のメール作成画面を開きます。',
            style: TextStyle(fontSize: 13, color: colors.secondaryText),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton(
                onPressed: onClose,
                style: colors.outlinedButtonStyle(),
                child: const Text('閉じる'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: onOpenMail,
                style: colors.filledButtonStyle(),
                child: const Text('メールを開く'),
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
  });

  final _DesktopPreviewColors colors;
  final double width;
  final double? height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.surface,
      elevation: 18,
      shadowColor: Colors.black.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: width,
        height: height,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          border: Border.all(color: colors.border),
          borderRadius: BorderRadius.circular(14),
        ),
        child: child,
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
        borderRadius: BorderRadius.circular(8),
        onTap: enabled ? onPressed : null,
        child: Container(
          height: 30,
          constraints: const BoxConstraints(minWidth: 68),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 17),
          decoration: BoxDecoration(
            color: background,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 13,
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
    required this.onPressed,
  });

  final _DesktopPreviewColors colors;
  final String label;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onPressed,
        child: Container(
          height: 20,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: 0.16),
            border: Border.all(color: colors.accent.withValues(alpha: 0.45)),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: colors.accent,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
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
      style: TextStyle(fontSize: 12, color: colors.secondaryText),
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
      height: 30,
      child: Row(
        children: [
          Text(title, style: const TextStyle(fontSize: 13)),
          const Spacer(),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onPressed ?? () {},
            child: Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.buttonBackground,
                border: Border.all(color: colors.buttonBorder),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 15, color: iconColor),
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
        InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onDecrease,
          child: const Icon(Icons.remove_circle_outline, size: 17),
        ),
        const SizedBox(width: 8),
        Text(value, style: const TextStyle(fontSize: 13)),
        const SizedBox(width: 8),
        InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onIncrease,
          child: const Icon(Icons.add_circle_outline, size: 17),
        ),
      ],
    );
  }
}

class _MenuValuePill extends StatelessWidget {
  const _MenuValuePill({
    required this.colors,
    required this.label,
    required this.onPressed,
  });

  final _DesktopPreviewColors colors;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onPressed,
      child: Container(
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
            Icon(
              Icons.keyboard_arrow_down,
              size: 14,
              color: colors.secondaryText,
            ),
          ],
        ),
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
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: colors.secondaryText),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: colors.secondaryText),
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
      : Colors.white.withValues(alpha: 0.42);

  Color get lapCard => isMonochrome
      ? Colors.black.withValues(alpha: 0.05)
      : Colors.white.withValues(alpha: 0.66);

  Color get inlineEditorBackground => isMonochrome
      ? Colors.white.withValues(alpha: 0.84)
      : Colors.white.withValues(alpha: 0.78);

  Color get memoFieldBackground => isMonochrome
      ? Colors.white.withValues(alpha: 0.76)
      : Colors.white.withValues(alpha: 0.70);

  Color get panelSurface =>
      isMonochrome ? const Color(0xFFF2F2F2) : const Color(0xFFF0F2F2);

  Color get menuGroupBackground => isMonochrome
      ? Colors.black.withValues(alpha: 0.04)
      : Colors.white.withValues(alpha: 0.42);

  Color get menuRowBackground => isMonochrome
      ? Colors.black.withValues(alpha: 0.07)
      : Colors.white.withValues(alpha: 0.42);

  Color get headerControl => isMonochrome
      ? Colors.black.withValues(alpha: 0.14)
      : Colors.black.withValues(alpha: 0.07);

  Color get selectedChip => isMonochrome
      ? Colors.black.withValues(alpha: 0.20)
      : Colors.black.withValues(alpha: 0.13);

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
    required this.memoFormatLabel,
    required this.timeFormatLabel,
  });

  final String text;
  final String headerText;
  final String memoFormatLabel;
  final String timeFormatLabel;
}

_SessionSummary _buildSessionSummary({
  required StopwatchController stopwatch,
  required Map<String, int> lapSeconds,
  required int totalSeconds,
  required _SummaryMemoFormat memoFormat,
  required _SummaryTimeFormat timeFormat,
}) {
  final lines = <String>[];
  if (stopwatch.laps.isEmpty) {
    lines.add('Splitはまだありません');
  } else {
    for (final lap in stopwatch.laps) {
      final elapsedSeconds = lapSeconds[lap.id] ?? lap.accumulatedSeconds;
      lines.add(
        '${lap.label}　(${_formatSummaryDuration(elapsedSeconds, timeFormat)})',
      );
      final memo = lap.memo.trim();
      if (memo.isEmpty) {
        continue;
      }
      switch (memoFormat) {
        case _SummaryMemoFormat.plain:
          lines.add(lap.memo);
        case _SummaryMemoFormat.bulleted:
          final paragraphs = lap.memo
              .split(RegExp(r'\r?\n'))
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty);
          for (final paragraph in paragraphs) {
            lines.add('   - $paragraph');
          }
      }
    }
  }

  final sessionTitle = stopwatch.session?.title ?? '';
  return _SessionSummary(
    text: lines.join('\n'),
    headerText:
        '$sessionTitle (${_formatSummaryDuration(totalSeconds, timeFormat)})',
    memoFormatLabel: memoFormat == _SummaryMemoFormat.bulleted ? '- メモ' : 'メモ',
    timeFormatLabel: _formatSummaryDuration(totalSeconds, timeFormat),
  );
}

String _formatSummaryDuration(int seconds, _SummaryTimeFormat format) {
  final safeSeconds = math.max(0, seconds);
  switch (format) {
    case _SummaryTimeFormat.decimalHours:
      return '${(safeSeconds / 3600).toStringAsFixed(1)}h';
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
