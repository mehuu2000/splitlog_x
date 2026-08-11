import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/session_models.dart';
import '../../../core/models/summary_format.dart';
import '../../../core/services/session_storage_service.dart';
import '../../../core/services/stopwatch_controller.dart';

const _mobileAppPlatformChannel = MethodChannel('splitlog_x/app');

List<SummaryFormatDefinition> _upsertMobileSummaryFormat(
  List<SummaryFormatDefinition> formats,
  SummaryFormatDefinition format,
) {
  final index = formats.indexWhere((candidate) => candidate.id == format.id);
  if (index < 0) {
    return [...formats, format];
  }
  return [
    for (var current = 0; current < formats.length; current += 1)
      if (current == index) format else formats[current],
  ];
}

SummaryFormatDefinition _createMobileSummaryFormatDraft(
  List<SummaryFormatDefinition> formats,
) {
  var suffix = 1;
  final names = formats.map((format) => format.name).toSet();
  while (names.contains('カスタム$suffix')) {
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

class MobileSessionView extends StatefulWidget {
  const MobileSessionView({super.key, this.storage});

  final SessionStorageService? storage;

  @override
  State<MobileSessionView> createState() => _MobileSessionViewState();
}

class _MobileSessionViewState extends State<MobileSessionView>
    with WidgetsBindingObserver {
  final List<StopwatchController> _stopwatches = [];
  SessionStorageService? _storage;
  late DateTime _clock;
  Timer? _ticker;
  int _selectedSessionIndex = 0;
  bool _storageReady = false;
  bool _storageWritable = true;
  bool _isMonochrome = false;
  bool _preservedDesktopLock = false;
  bool _preservedShortcutsEnabled = true;
  int _ringHoursPerCycle = defaultRingHoursPerCycle;
  SplitAccumulationMode _defaultSplitMode = SplitAccumulationMode.radio;
  String _selectedSummaryFormatId = defaultSummaryFormatId;
  List<SummaryFormatDefinition> _customSummaryFormats = [];
  String _summaryTimeFormat = defaultSummaryTimeFormatName;

  StopwatchController get _stopwatch => _stopwatches[_selectedSessionIndex];

  int get _totalSeconds => _stopwatch.elapsedSessionSeconds(at: _clock);

  List<String> get _sessionTitles => [
    for (final stopwatch in _stopwatches)
      stopwatch.session?.title ?? _dateTitle(_clock),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clock = DateTime.now();
    _stopwatches.add(
      StopwatchController(
        initialSnapshot: _emptySessionSnapshot(
          _clock,
          _dateTitle(_clock),
          splitMode: _defaultSplitMode,
        ),
      ),
    );
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _stopwatch.state != SessionState.running) {
        return;
      }
      setState(() {
        _clock = DateTime.now();
      });
    });
    unawaited(_initializeStorage());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (mounted) {
          setState(() {
            _clock = DateTime.now();
          });
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _persistState();
        final storage = _storage;
        if (storage != null) {
          unawaited(storage.flush());
        }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _persistState();
    final storage = _storage;
    if (storage != null) {
      unawaited(storage.flush());
    }
    super.dispose();
  }

  Future<void> _initializeStorage() async {
    try {
      final storage =
          widget.storage ??
          await SessionStorageService.createForCurrentPlatform();
      final snapshot = await storage.load();
      if (!mounted) {
        return;
      }
      _storage = storage;
      setState(() {
        if (snapshot != null && snapshot.sessions.isNotEmpty) {
          _restoreStorageSnapshot(snapshot);
        }
        _clock = DateTime.now();
        _storageReady = true;
      });
    } on SessionStorageReadException {
      if (!mounted) {
        return;
      }
      setState(() {
        _storageWritable = false;
        _storageReady = true;
      });
      _showMessage('保存データを読み込めませんでした');
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _storageWritable = false;
        _storageReady = true;
      });
      _showMessage('保存先を準備できませんでした');
    }
  }

  void _restoreStorageSnapshot(SplitLogStorageSnapshot snapshot) {
    _stopwatches
      ..clear()
      ..addAll(
        snapshot.sessions.map(
          (session) => StopwatchController(initialSnapshot: session),
        ),
      );
    _selectedSessionIndex = snapshot.selectedSessionIndex.clamp(
      0,
      _stopwatches.length - 1,
    );
    final settings = snapshot.settings;
    _isMonochrome = settings.isMonochrome;
    _preservedDesktopLock = settings.isLocked;
    _preservedShortcutsEnabled = settings.shortcutsEnabled;
    _ringHoursPerCycle = settings.ringHoursPerCycle.clamp(1, 24);
    _defaultSplitMode = settings.defaultSplitMode;
    _selectedSummaryFormatId = resolveSummaryFormat(
      settings.selectedSummaryFormatId,
      settings.customSummaryFormats,
    ).id;
    _customSummaryFormats = List.of(settings.customSummaryFormats);
    _summaryTimeFormat = _normalizedSummaryTimeFormat(
      settings.summaryTimeFormat,
    );
  }

  SplitLogStorageSnapshot _storageSnapshot() {
    return SplitLogStorageSnapshot(
      savedAt: DateTime.now(),
      sessions: [for (final stopwatch in _stopwatches) stopwatch.snapshot()],
      selectedSessionIndex: _selectedSessionIndex,
      settings: SplitLogSettingsSnapshot(
        isLocked: _preservedDesktopLock,
        isMonochrome: _isMonochrome,
        ringHoursPerCycle: _ringHoursPerCycle,
        defaultSplitMode: _defaultSplitMode,
        selectedSummaryFormatId: _selectedSummaryFormatId,
        customSummaryFormats: _customSummaryFormats,
        summaryTimeFormat: _summaryTimeFormat,
        shortcutsEnabled: _preservedShortcutsEnabled,
      ),
    );
  }

  void _persistState() {
    final storage = _storage;
    if (!_storageReady || !_storageWritable || storage == null) {
      return;
    }
    final snapshot = _storageSnapshot();
    unawaited(
      storage.save(snapshot).catchError((Object _) {
        if (mounted) {
          _showMessage('データの保存に失敗しました');
        }
      }),
    );
  }

  void _refresh({bool persist = false}) {
    setState(() {
      _clock = DateTime.now();
    });
    if (persist) {
      _persistState();
    }
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

  void _activateLap(String lapId) {
    final now = DateTime.now();
    if (_stopwatch.splitAccumulationMode == SplitAccumulationMode.checkbox) {
      _stopwatch.toggleLapActive(lapId, at: now);
    }
    _stopwatch.selectLap(lapId, at: now);
    _refresh(persist: true);
  }

  void _setSplitMode(SplitAccumulationMode mode) {
    _stopwatch.setSplitAccumulationMode(mode, at: DateTime.now());
    _refresh(persist: true);
  }

  void _selectSession(int index) {
    if (index < 0 ||
        index >= _stopwatches.length ||
        index == _selectedSessionIndex) {
      return;
    }
    final now = DateTime.now();
    if (_stopwatch.state == SessionState.running) {
      _stopwatch.finishSession(at: now);
    }
    setState(() {
      _selectedSessionIndex = index;
      _clock = now;
    });
    _persistState();
  }

  void _addSession() {
    final now = DateTime.now();
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

  Future<void> _editSessionTitle() async {
    final title = await _showTextEditor(
      title: 'セッション名',
      initialValue: _stopwatch.session?.title ?? _dateTitle(_clock),
    );
    if (title == null || !mounted) {
      return;
    }
    _stopwatch.updateSessionTitle(title);
    _refresh(persist: true);
  }

  Future<void> _editLapLabel(WorkLap lap) async {
    final label = await _showTextEditor(
      title: 'Split名',
      initialValue: lap.label,
    );
    if (label == null || !mounted) {
      return;
    }
    _stopwatch.updateLapLabel(lap.id, label);
    _refresh(persist: true);
  }

  Future<String?> _showTextEditor({
    required String title,
    required String initialValue,
  }) async {
    return showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: _MobileColors(isMonochrome: _isMonochrome).surface,
      builder: (context) => _MobileTextEditorDialog(
        title: title,
        initialValue: initialValue,
        colors: _MobileColors(isMonochrome: _isMonochrome),
      ),
    );
  }

  Future<void> _openMemo(WorkLap lap) async {
    final seconds = _stopwatch.displayedLapSecondsMap(at: DateTime.now());
    final result = await Navigator.of(context).push<_MobileMemoResult>(
      MaterialPageRoute(
        builder: (context) => _MobileMemoScreen(
          colors: _MobileColors(isMonochrome: _isMonochrome),
          initialLabel: lap.label,
          initialMemo: lap.memo,
          elapsedText: _formatDuration(
            seconds[lap.id] ?? lap.accumulatedSeconds,
          ),
        ),
      ),
    );
    if (result == null || !mounted) {
      return;
    }
    _stopwatch.updateLapLabel(lap.id, result.label);
    _stopwatch.updateLapMemo(lap.id, result.memo);
    _refresh(persist: true);
  }

  Future<void> _openSummary() async {
    final result = await Navigator.of(context).push<_MobileSummaryResult>(
      MaterialPageRoute(
        builder: (context) => _MobileSummaryScreen(
          colors: _MobileColors(isMonochrome: _isMonochrome),
          stopwatch: _stopwatch,
          at: DateTime.now(),
          selectedFormatId: _selectedSummaryFormatId,
          customFormats: _customSummaryFormats,
          timeFormat: _summaryTimeFormat,
        ),
      ),
    );
    if (result == null || !mounted) {
      return;
    }
    setState(() {
      _selectedSummaryFormatId = result.formatId;
      _customSummaryFormats = List.of(result.customFormats);
      _summaryTimeFormat = result.timeFormat;
      _clock = DateTime.now();
    });
    _persistState();
  }

  Future<void> _openSettings() async {
    final result = await Navigator.of(context).push<_MobileSettingsResult>(
      MaterialPageRoute(
        builder: (context) => _MobileSettingsScreen(
          isMonochrome: _isMonochrome,
          ringHoursPerCycle: _ringHoursPerCycle,
          defaultSplitMode: _defaultSplitMode,
          selectedFormatId: _selectedSummaryFormatId,
          customFormats: _customSummaryFormats,
          timeFormat: _summaryTimeFormat,
        ),
      ),
    );
    if (result == null || !mounted) {
      return;
    }
    setState(() {
      _isMonochrome = result.isMonochrome;
      _ringHoursPerCycle = result.ringHoursPerCycle;
      _defaultSplitMode = result.defaultSplitMode;
      _selectedSummaryFormatId = result.selectedFormatId;
      _customSummaryFormats = List.of(result.customFormats);
      _summaryTimeFormat = result.timeFormat;
    });
    switch (result.dataAction) {
      case _MobileSettingsDataAction.importLegacyFile:
        await _importLegacyDataFromFile();
      case _MobileSettingsDataAction.deleteSessionData:
        _deleteAllSessionData();
      case _MobileSettingsDataAction.deleteLapData:
        _deleteAllLapData();
      case _MobileSettingsDataAction.resetSettings:
        _resetSettings();
      case _MobileSettingsDataAction.initializeAllData:
        _initializeAllData();
      case null:
        _persistState();
    }
  }

  Future<void> _importLegacyDataFromFile() async {
    final storage = _storage;
    if (storage == null) {
      _showMessage('保存先を準備できていません');
      return;
    }
    try {
      final content = await _mobileAppPlatformChannel.invokeMethod<String>(
        'chooseLegacyFile',
      );
      if (!mounted || content == null) {
        return;
      }
      final snapshot = await storage.importLegacySnapshotFromContent(content);
      if (!mounted) {
        return;
      }
      if (snapshot == null || snapshot.sessions.isEmpty) {
        _showMessage('読み込めるセッションがありませんでした');
        return;
      }
      setState(() {
        _storageWritable = true;
        _restoreStorageSnapshot(snapshot);
        _clock = DateTime.now();
      });
      _persistState();
      _showMessage('旧データをインポートしました');
    } on Object {
      if (mounted) {
        _showMessage('sessions.jsonの読み込みに失敗しました');
      }
    }
  }

  Future<void> _confirmReset() async {
    final confirmed = await _showConfirmation(
      title: 'セッションをリセットしますか？',
      message: '現在のセッションのSplitと計測時間を削除します。',
      confirmLabel: 'リセット',
    );
    if (!confirmed || !mounted) {
      return;
    }
    _stopwatch.reset(at: DateTime.now());
    _refresh(persist: true);
  }

  Future<void> _confirmDelete() async {
    final confirmed = await _showConfirmation(
      title: 'セッションを削除しますか？',
      message: 'この操作は取り消せません。',
      confirmLabel: '削除',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    final now = DateTime.now();
    setState(() {
      if (_stopwatches.length == 1) {
        _stopwatch.reset(at: now);
      } else {
        _stopwatches.removeAt(_selectedSessionIndex);
        _selectedSessionIndex = math.min(
          _selectedSessionIndex,
          _stopwatches.length - 1,
        );
      }
      _clock = now;
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
    _showMessage('セッション情報を削除しました');
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
    _showMessage('Split情報を削除しました');
  }

  void _resetSettings() {
    setState(() {
      _isMonochrome = false;
      _ringHoursPerCycle = defaultRingHoursPerCycle;
      _defaultSplitMode = SplitAccumulationMode.radio;
      _selectedSummaryFormatId = defaultSummaryFormatId;
      _customSummaryFormats = [];
      _summaryTimeFormat = defaultSummaryTimeFormatName;
    });
    _persistState();
    _showMessage('設定を初期化しました');
  }

  void _initializeAllData() {
    final now = DateTime.now();
    setState(() {
      _storageWritable = true;
      _isMonochrome = false;
      _ringHoursPerCycle = defaultRingHoursPerCycle;
      _defaultSplitMode = SplitAccumulationMode.radio;
      _selectedSummaryFormatId = defaultSummaryFormatId;
      _customSummaryFormats = [];
      _summaryTimeFormat = defaultSummaryTimeFormatName;
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
    _showMessage('全データを初期化しました');
  }

  Future<bool> _showConfirmation({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final colors = _MobileColors(isMonochrome: _isMonochrome);
    return _showMobileConfirmationSheet(
      context: context,
      colors: colors,
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      destructive: destructive,
    );
  }

  void _showMessage(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    });
  }

  String get _primaryActionLabel {
    if (_stopwatch.state == SessionState.running) {
      return '停止';
    }
    return _stopwatch.laps.isEmpty ? '開始' : '再開';
  }

  String get _stateLabel => switch (_stopwatch.state) {
    SessionState.running => '計測中',
    SessionState.paused => '一時停止',
    SessionState.idle => '未開始',
    SessionState.stopped || SessionState.finished => '停止中',
  };

  @override
  Widget build(BuildContext context) {
    final colors = _MobileColors(isMonochrome: _isMonochrome);
    if (!_storageReady) {
      return Scaffold(
        backgroundColor: colors.background,
        body: const SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }

    final lapSeconds = _stopwatch.displayedLapSecondsMap(at: _clock);
    return Scaffold(
      key: const ValueKey<String>('mobile-session-view'),
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          children: [
            _MobileHeader(
              colors: colors,
              sessions: _sessionTitles,
              selectedSessionIndex: _selectedSessionIndex,
              onSelectSession: _selectSession,
              onEditSession: _editSessionTitle,
              onAddSession: _addSession,
              onOpenSettings: _openSettings,
            ),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: _MobileSessionOverview(
                      colors: colors,
                      stateLabel: _stateLabel,
                      totalSeconds: _totalSeconds,
                      ringHoursPerCycle: _ringHoursPerCycle,
                      laps: _stopwatch.laps,
                      lapSeconds: lapSeconds,
                      onEditRingCycle: _openSettings,
                      onOpenSummary: _openSummary,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _MobileSplitSectionHeader(
                      colors: colors,
                      count: _stopwatch.laps.length,
                      mode: _stopwatch.splitAccumulationMode,
                      onModeChanged: _setSplitMode,
                    ),
                  ),
                  if (_stopwatch.laps.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Text(
                          '開始すると最初のSplitが作成されます',
                          style: TextStyle(
                            color: colors.secondaryText,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    )
                  else
                    SliverList.builder(
                      itemCount: _stopwatch.laps.length,
                      itemBuilder: (context, index) {
                        final lap = _stopwatch.laps[index];
                        return _MobileLapRow(
                          key: ValueKey<String>('mobile-lap-${lap.id}'),
                          colors: colors,
                          lap: lap,
                          elapsedSeconds:
                              lapSeconds[lap.id] ?? lap.accumulatedSeconds,
                          mode: _stopwatch.splitAccumulationMode,
                          selected: _stopwatch.selectedLapId == lap.id,
                          active: _stopwatch.activeLapIds.contains(lap.id),
                          onActivate: () => _activateLap(lap.id),
                          onEditLabel: () => _editLapLabel(lap),
                          onOpenMemo: () => _openMemo(lap),
                        );
                      },
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ),
            ),
            _MobileBottomActions(
              colors: colors,
              primaryLabel: _primaryActionLabel,
              splitEnabled: _stopwatch.state == SessionState.running,
              onPrimary: _togglePrimaryAction,
              onSplit: _finishLap,
              onReset: _confirmReset,
              onDelete: _confirmDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileHeader extends StatelessWidget {
  const _MobileHeader({
    required this.colors,
    required this.sessions,
    required this.selectedSessionIndex,
    required this.onSelectSession,
    required this.onEditSession,
    required this.onAddSession,
    required this.onOpenSettings,
  });

  final _MobileColors colors;
  final List<String> sessions;
  final int selectedSessionIndex;
  final ValueChanged<int> onSelectSession;
  final VoidCallback onEditSession;
  final VoidCallback onAddSession;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      child: Column(
        children: [
          SizedBox(
            height: 48,
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.accent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.timer_outlined,
                    size: 20,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'SplitLog',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.primaryText,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _MobileCircleIconButton(
                  colors: colors,
                  tooltip: 'セッションを追加',
                  icon: Icons.add,
                  onPressed: onAddSession,
                ),
                const SizedBox(width: 4),
                _MobileCircleIconButton(
                  colors: colors,
                  tooltip: '設定',
                  icon: Icons.settings_outlined,
                  onPressed: onOpenSettings,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Material(
            key: const ValueKey<String>('mobile-session-menu'),
            color: colors.control,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () async {
                final selected = await _showMobileSelectionSheet<int>(
                  context: context,
                  colors: colors,
                  title: 'セッションを選択',
                  selectedValue: selectedSessionIndex,
                  options: [
                    for (var index = 0; index < sessions.length; index += 1)
                      _MobileSelectionOption<int>(
                        value: index,
                        label: sessions[index],
                        icon: Icons.timer_outlined,
                      ),
                  ],
                );
                if (selected != null) {
                  onSelectSession(selected);
                }
              },
              child: SizedBox(
                height: 48,
                child: Row(
                  children: [
                    const SizedBox(width: 13),
                    Icon(Icons.layers_outlined, size: 18, color: colors.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'セッション',
                            style: TextStyle(
                              color: colors.secondaryText,
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            sessions[selectedSessionIndex],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.primaryText,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.keyboard_arrow_down,
                      size: 20,
                      color: colors.secondaryText,
                    ),
                    SizedBox(
                      key: const ValueKey<String>(
                        'mobile-session-title-editor',
                      ),
                      width: 44,
                      height: 44,
                      child: IconButton(
                        tooltip: 'セッション名を編集',
                        onPressed: onEditSession,
                        icon: Icon(
                          Icons.edit_outlined,
                          size: 18,
                          color: colors.utility,
                        ),
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

class _MobileSessionOverview extends StatelessWidget {
  const _MobileSessionOverview({
    required this.colors,
    required this.stateLabel,
    required this.totalSeconds,
    required this.ringHoursPerCycle,
    required this.laps,
    required this.lapSeconds,
    required this.onEditRingCycle,
    required this.onOpenSummary,
  });

  final _MobileColors colors;
  final String stateLabel;
  final int totalSeconds;
  final int ringHoursPerCycle;
  final List<WorkLap> laps;
  final Map<String, int> lapSeconds;
  final VoidCallback onEditRingCycle;
  final VoidCallback onOpenSummary;

  @override
  Widget build(BuildContext context) {
    final hasOuterRing = totalSeconds >= ringHoursPerCycle * 3600;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: SizedBox(
        height: 224,
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: _MobileActionChip(
                colors: colors,
                icon: Icons.autorenew,
                label: '${ringHoursPerCycle}h',
                tooltip: 'リング周期を変更',
                onPressed: onEditRingCycle,
              ),
            ),
            Align(
              alignment: Alignment.topRight,
              child: _MobileActionChip(
                colors: colors,
                icon: Icons.description_outlined,
                label: 'サマリー',
                tooltip: 'サマリー',
                onPressed: onOpenSummary,
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 210,
                height: 210,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: const Size.square(210),
                      painter: _MobileTimelinePainter(
                        colors: colors,
                        laps: laps,
                        lapSeconds: lapSeconds,
                        totalSeconds: totalSeconds,
                        ringHoursPerCycle: ringHoursPerCycle,
                      ),
                    ),
                    SizedBox(
                      width: hasOuterRing ? 94 : 142,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '合計時間',
                            style: TextStyle(
                              color: colors.secondaryText,
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              _formatDuration(totalSeconds),
                              key: const ValueKey<String>(
                                'mobile-total-elapsed',
                              ),
                              maxLines: 1,
                              style: TextStyle(
                                color: colors.primaryText,
                                fontSize: 27,
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 7),
                          _MobileStatusBadge(
                            colors: colors,
                            label: stateLabel,
                            running: stateLabel == '計測中',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileSplitSectionHeader extends StatelessWidget {
  const _MobileSplitSectionHeader({
    required this.colors,
    required this.count,
    required this.mode,
    required this.onModeChanged,
  });

  final _MobileColors colors;
  final int count;
  final SplitAccumulationMode mode;
  final ValueChanged<SplitAccumulationMode> onModeChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Row(
        children: [
          Text(
            'Split',
            style: TextStyle(
              color: colors.primaryText,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 7),
          Container(
            height: 22,
            constraints: const BoxConstraints(minWidth: 22),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.accentSoft,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                color: colors.accent,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Spacer(),
          _MobileSplitModeControl(
            key: const ValueKey<String>('mobile-split-mode'),
            colors: colors,
            mode: mode,
            onChanged: onModeChanged,
          ),
        ],
      ),
    );
  }
}

class _MobileLapRow extends StatelessWidget {
  const _MobileLapRow({
    super.key,
    required this.colors,
    required this.lap,
    required this.elapsedSeconds,
    required this.mode,
    required this.selected,
    required this.active,
    required this.onActivate,
    required this.onEditLabel,
    required this.onOpenMemo,
  });

  final _MobileColors colors;
  final WorkLap lap;
  final int elapsedSeconds;
  final SplitAccumulationMode mode;
  final bool selected;
  final bool active;
  final VoidCallback onActivate;
  final VoidCallback onEditLabel;
  final VoidCallback onOpenMemo;

  @override
  Widget build(BuildContext context) {
    final splitColor = colors.lapColor(lap.index);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 5, 16, 0),
      child: Material(
        color: selected ? colors.selectedRow : colors.lapCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: colors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onActivate,
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.fromLTRB(4, 5, 7, 5),
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  height: 48,
                  child: IconButton(
                    tooltip: mode == SplitAccumulationMode.radio
                        ? 'Splitを選択'
                        : 'Splitの配分を切り替え',
                    padding: EdgeInsets.zero,
                    onPressed: onActivate,
                    icon: Icon(
                      mode == SplitAccumulationMode.radio
                          ? selected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off
                          : active
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 21,
                      color: selected || active
                          ? colors.accent
                          : colors.secondaryText,
                    ),
                  ),
                ),
                Expanded(
                  child: InkWell(
                    key: ValueKey<String>('mobile-lap-label-${lap.id}'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: onEditLabel,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          Container(
                            key: ValueKey<String>('mobile-lap-color-${lap.id}'),
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: splitColor, width: 3),
                            ),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  lap.label,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: colors.primaryText,
                                    fontSize: 14,
                                    height: 1.25,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (lap.memo.trim().isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    lap.memo.replaceAll('\n', ' '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: colors.secondaryText,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _formatDuration(elapsedSeconds),
                      style: TextStyle(
                        color: colors.primaryText,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Split ${lap.index}',
                      style: TextStyle(
                        color: colors.secondaryText,
                        fontSize: 9,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 3),
                SizedBox(
                  width: 44,
                  height: 48,
                  child: IconButton(
                    tooltip: 'Splitメモ',
                    padding: EdgeInsets.zero,
                    onPressed: onOpenMemo,
                    icon: Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: lap.memo.trim().isEmpty
                            ? colors.control
                            : colors.accentSoft,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        lap.memo.trim().isEmpty
                            ? Icons.note_add_outlined
                            : Icons.sticky_note_2_outlined,
                        color: lap.memo.trim().isEmpty
                            ? colors.utility
                            : colors.accent,
                        size: 17,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileBottomActions extends StatelessWidget {
  const _MobileBottomActions({
    required this.colors,
    required this.primaryLabel,
    required this.splitEnabled,
    required this.onPrimary,
    required this.onSplit,
    required this.onReset,
    required this.onDelete,
  });

  final _MobileColors colors;
  final String primaryLabel;
  final bool splitEnabled;
  final VoidCallback onPrimary;
  final VoidCallback onSplit;
  final VoidCallback onReset;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: colors.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            flex: 11,
            child: SizedBox(
              height: 50,
              child: FilledButton.icon(
                key: const ValueKey<String>('mobile-primary-action'),
                onPressed: onPrimary,
                icon: Icon(
                  primaryLabel == '停止' ? Icons.stop : Icons.play_arrow,
                  size: 19,
                ),
                label: Text(primaryLabel),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.accent,
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 9,
            child: SizedBox(
              height: 50,
              child: OutlinedButton.icon(
                key: const ValueKey<String>('mobile-split-action'),
                onPressed: splitEnabled ? onSplit : null,
                icon: const Icon(Icons.call_split, size: 18),
                label: const Text('Split'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.primaryText,
                  backgroundColor: colors.surface,
                  disabledForegroundColor: colors.softText,
                  side: BorderSide(color: colors.buttonBorder),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _MobileUtilityButton(
            colors: colors,
            tooltip: 'その他の操作',
            icon: Icons.more_horiz,
            size: 50,
            onPressed: () => _showActions(context),
          ),
        ],
      ),
    );
  }

  Future<void> _showActions(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: colors.surface,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'セッション操作',
              style: TextStyle(
                color: colors.primaryText,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            _MobileSheetAction(
              colors: colors,
              icon: Icons.refresh,
              title: '現在のセッションをリセット',
              subtitle: 'Splitと計測時間を削除します',
              onPressed: () {
                Navigator.pop(sheetContext);
                onReset();
              },
            ),
            const SizedBox(height: 8),
            _MobileSheetAction(
              colors: colors,
              icon: Icons.delete_outline,
              title: '現在のセッションを削除',
              subtitle: 'この操作は取り消せません',
              destructive: true,
              onPressed: () {
                Navigator.pop(sheetContext);
                onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileActionChip extends StatelessWidget {
  const _MobileActionChip({
    required this.colors,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final _MobileColors colors;
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: colors.control,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              border: Border.all(color: colors.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: colors.accent),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: colors.primaryText,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileStatusBadge extends StatelessWidget {
  const _MobileStatusBadge({
    required this.colors,
    required this.label,
    required this.running,
  });

  final _MobileColors colors;
  final String label;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final foreground = running ? colors.accent : colors.secondaryText;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: running ? colors.accentSoft : colors.control,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: foreground,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileSheetAction extends StatelessWidget {
  const _MobileSheetAction({
    required this.colors,
    required this.icon,
    required this.title,
    required this.onPressed,
    this.subtitle,
    this.destructive = false,
  });

  final _MobileColors colors;
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final foreground = destructive ? colors.danger : colors.primaryText;
    return Material(
      color: destructive ? colors.dangerSoft : colors.control,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Container(
          constraints: const BoxConstraints(minHeight: 58),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            children: [
              Icon(icon, size: 20, color: foreground),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          color: destructive
                              ? colors.danger.withValues(alpha: 0.72)
                              : colors.secondaryText,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: foreground),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileSelectionOption<T> {
  const _MobileSelectionOption({
    required this.value,
    required this.label,
    this.icon,
    this.destructive = false,
  });

  final T value;
  final String label;
  final IconData? icon;
  final bool destructive;
}

Future<T?> _showMobileSelectionSheet<T>({
  required BuildContext context,
  required _MobileColors colors,
  required String title,
  required List<_MobileSelectionOption<T>> options,
  T? selectedValue,
}) {
  return showModalBottomSheet<T>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: colors.surface,
    builder: (sheetContext) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Text(
              title,
              style: TextStyle(
                color: colors.primaryText,
                fontSize: 19,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              itemCount: options.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final option = options[index];
                final selected = option.value == selectedValue;
                final foreground = option.destructive
                    ? colors.danger
                    : colors.primaryText;
                return Material(
                  color: selected ? colors.accentSoft : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => Navigator.pop(sheetContext, option.value),
                    child: SizedBox(
                      height: 52,
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          if (option.icon != null) ...[
                            Icon(option.icon, size: 19, color: foreground),
                            const SizedBox(width: 12),
                          ],
                          Expanded(
                            child: Text(
                              option.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: foreground,
                                fontSize: 14,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          if (selected)
                            Icon(Icons.check, size: 20, color: colors.accent),
                          const SizedBox(width: 14),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

Future<bool> _showMobileConfirmationSheet({
  required BuildContext context,
  required _MobileColors colors,
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  return await showModalBottomSheet<bool>(
        context: context,
        useSafeArea: true,
        showDragHandle: true,
        backgroundColor: colors.surface,
        builder: (sheetContext) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: destructive ? colors.dangerSoft : colors.accentSoft,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  destructive ? Icons.warning_amber : Icons.info_outline,
                  size: 23,
                  color: destructive ? colors.danger : colors.accent,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.primaryText,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.secondaryText,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _MobileCompactTextButton(
                      colors: colors,
                      label: 'キャンセル',
                      onPressed: () => Navigator.pop(sheetContext, false),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MobileCompactTextButton(
                      colors: colors,
                      label: confirmLabel,
                      prominent: !destructive,
                      destructive: destructive,
                      onPressed: () => Navigator.pop(sheetContext, true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ) ??
      false;
}

class _MobileCircleIconButton extends StatelessWidget {
  const _MobileCircleIconButton({
    required this.colors,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final _MobileColors colors;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: colors.headerControl,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, size: 19, color: colors.utility),
          ),
        ),
      ),
    );
  }
}

class _MobileUtilityButton extends StatelessWidget {
  const _MobileUtilityButton({
    required this.colors,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 44,
  });

  final _MobileColors colors;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: colors.buttonBackground,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: colors.buttonBorder),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 19, color: colors.utility),
          ),
        ),
      ),
    );
  }
}

class _MobileSplitModeControl extends StatelessWidget {
  const _MobileSplitModeControl({
    super.key,
    required this.colors,
    required this.mode,
    required this.onChanged,
  });

  final _MobileColors colors;
  final SplitAccumulationMode mode;
  final ValueChanged<SplitAccumulationMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      width: 166,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colors.headerControl,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          _buildOption(
            mode: SplitAccumulationMode.radio,
            icon: Icons.radio_button_checked,
            label: 'ラジオ',
          ),
          _buildOption(
            mode: SplitAccumulationMode.checkbox,
            icon: Icons.check_box_outlined,
            label: 'チェック',
          ),
        ],
      ),
    );
  }

  Widget _buildOption({
    required SplitAccumulationMode mode,
    required IconData icon,
    required String label,
  }) {
    final selected = this.mode == mode;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: () => onChanged(mode),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? colors.selectedChip : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 14,
                color: selected ? colors.accent : colors.utility,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: selected ? colors.accent : colors.primaryText,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileCompactTextButton extends StatelessWidget {
  const _MobileCompactTextButton({
    required this.colors,
    required this.label,
    required this.onPressed,
    this.prominent = false,
    this.destructive = false,
  });

  final _MobileColors colors;
  final String label;
  final VoidCallback onPressed;
  final bool prominent;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final background = destructive
        ? const Color(0xFFC94848)
        : prominent
        ? colors.accent
        : colors.buttonBackground;
    final foreground = prominent || destructive
        ? Colors.white
        : colors.primaryText;
    return SizedBox(
      height: 44,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: foreground,
          backgroundColor: background,
          padding: const EdgeInsets.symmetric(horizontal: 15),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: prominent || destructive
                  ? Colors.transparent
                  : colors.buttonBorder,
            ),
          ),
        ),
        child: Text(label),
      ),
    );
  }
}

class _MobileMenuPill extends StatelessWidget {
  const _MobileMenuPill({
    required this.colors,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.accent = false,
  });

  final _MobileColors colors;
  final String label;
  final String tooltip;
  final VoidCallback onPressed;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final foreground = accent ? colors.accent : colors.primaryText;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: accent ? colors.accentSoft : colors.buttonBackground,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: Container(
            height: 44,
            constraints: const BoxConstraints(minWidth: 78, maxWidth: 154),
            padding: const EdgeInsets.symmetric(horizontal: 11),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(
                color: accent
                    ? colors.accent.withValues(alpha: 0.28)
                    : colors.buttonBorder,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 12,
                      fontWeight: accent ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 3),
                Icon(Icons.keyboard_arrow_down, size: 16, color: foreground),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileTextEditorDialog extends StatefulWidget {
  const _MobileTextEditorDialog({
    required this.title,
    required this.initialValue,
    required this.colors,
  });

  final String title;
  final String initialValue;
  final _MobileColors colors;

  @override
  State<_MobileTextEditorDialog> createState() =>
      _MobileTextEditorDialogState();
}

class _MobileTextEditorDialogState extends State<_MobileTextEditorDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.pop(context, _controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedPadding(
      duration: const Duration(milliseconds: 160),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            style: TextStyle(
              color: widget.colors.primaryText,
              fontSize: 19,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey<String>('mobile-name-editor-field'),
            controller: _controller,
            autofocus: true,
            maxLines: 1,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            style: const TextStyle(fontSize: 15),
            decoration: _mobileFieldDecoration(widget.colors),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _MobileCompactTextButton(
                  colors: widget.colors,
                  label: 'キャンセル',
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MobileCompactTextButton(
                  colors: widget.colors,
                  label: '保存',
                  prominent: true,
                  onPressed: _save,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MobilePageHeader extends StatelessWidget {
  const _MobilePageHeader({
    required this.colors,
    required this.title,
    required this.onClose,
    this.actions = const [],
  });

  final _MobileColors colors;
  final String title;
  final VoidCallback onClose;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: colors.surface,
      child: Row(
        children: [
          _MobileUtilityButton(
            colors: colors,
            icon: Icons.close,
            tooltip: '閉じる',
            size: 44,
            onPressed: onClose,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.primaryText,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

class _MobileGuideScreen extends StatefulWidget {
  const _MobileGuideScreen({required this.colors});

  final _MobileColors colors;

  @override
  State<_MobileGuideScreen> createState() => _MobileGuideScreenState();
}

class _MobileGuideScreenState extends State<_MobileGuideScreen> {
  static const _sections = [
    _MobileGuideSection(
      title: '計測を始める・区切る',
      summary: '開始・停止・再開とSplitの基本操作',
      details: [
        '開始で計測を始め、停止と再開で同じセッションの計測を続けます。',
        '計測中にSplitを押すと現在の区切りを確定し、次のSplitを作成します。',
        '全体経過とリングで、セッション全体の経過時間を確認できます。',
      ],
    ),
    _MobileGuideSection(
      title: 'セッションを管理する',
      summary: '切り替え・追加・名前変更・整理',
      details: [
        '上部のセッション名から、表示するセッションを切り替えられます。',
        '表示中のセッション名をタップすると、名前を編集できます。',
        'プラスボタンで新しいセッションを追加します。追加や切り替えを行うと、計測中のセッションは停止します。',
        '下部のその他ボタンから、現在のセッションをリセットまたは削除できます。',
      ],
    ),
    _MobileGuideSection(
      title: 'Splitを編集・配分する',
      summary: '名前の編集と時間の割り当て方法',
      details: [
        'Split名をタップすると名前を編集できます。',
        'ラジオ配分では、選択中のSplitに経過時間が加算されます。',
        'チェック配分では、チェックしたSplitに経過秒を順番に分配します。',
        'Split見出し右側のボタンから、配分モードを切り替えます。',
      ],
    ),
    _MobileGuideSection(
      title: 'メモを記録する',
      summary: 'Splitごとの作業内容を残す',
      details: [
        '各Splitのメモアイコンから、Split名とメモを編集できます。',
        'メモ画面には、そのSplitに割り当てられた経過時間も表示されます。',
        '閉じるまたは保存で編集内容を確定し、端末内へ保存します。',
      ],
    ),
    _MobileGuideSection(
      title: 'サマリーを作成する',
      summary: '作業記録を整えてコピーする',
      details: [
        'サマリーボタンで、表示中のセッションから一覧テキストを作成します。',
        'サマリー本文はコピー前に直接編集できます。',
        '表示形式と時間形式を選び、コピーボタンでクリップボードへコピーします。',
      ],
    ),
    _MobileGuideSection(
      title: '表示とデータを管理する',
      summary: 'テーマ・リング周期・初期値・ローカル保存',
      details: [
        '設定からテーマ、リング周期、新規セッションの初期配分モードを変更できます。',
        '設定のデータ管理からsessions.jsonを選び、旧SplitLogの記録を手動で取り込めます。',
        'セッション、Split、メモ、設定はこの端末内に保存され、ほかの端末とは自動同期されません。',
        'アプリをバックグラウンドへ移しても、復帰時は開始時刻から正しい経過時間を復元します。',
      ],
    ),
  ];

  int? _expandedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          children: [
            _MobilePageHeader(
              colors: colors,
              title: '操作説明',
              onClose: () => Navigator.pop(context),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                itemCount: _sections.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final section = _sections[index];
                  final expanded = _expandedIndex == index;
                  return AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    child: Container(
                      decoration: BoxDecoration(
                        color: colors.section,
                        border: Border.all(color: colors.border),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () {
                              setState(() {
                                _expandedIndex = expanded ? null : index;
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 13,
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
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          section.summary,
                                          style: TextStyle(
                                            color: colors.secondaryText,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Icon(
                                    expanded
                                        ? Icons.keyboard_arrow_up
                                        : Icons.keyboard_arrow_down,
                                    color: colors.secondaryText,
                                    size: 17,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (expanded)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.fromLTRB(14, 12, 14, 5),
                              decoration: BoxDecoration(
                                color: colors.control,
                                border: Border(
                                  top: BorderSide(color: colors.border),
                                ),
                              ),
                              child: Column(
                                children: [
                                  for (final detail in section.details)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 6,
                                            ),
                                            child: Container(
                                              width: 4,
                                              height: 4,
                                              decoration: BoxDecoration(
                                                color: colors.accent,
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
                                                height: 1.5,
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
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileGuideSection {
  const _MobileGuideSection({
    required this.title,
    required this.summary,
    required this.details,
  });

  final String title;
  final String summary;
  final List<String> details;
}

class _MobileMemoResult {
  const _MobileMemoResult({required this.label, required this.memo});

  final String label;
  final String memo;
}

class _MobileMemoScreen extends StatefulWidget {
  const _MobileMemoScreen({
    required this.colors,
    required this.initialLabel,
    required this.initialMemo,
    required this.elapsedText,
  });

  final _MobileColors colors;
  final String initialLabel;
  final String initialMemo;
  final String elapsedText;

  @override
  State<_MobileMemoScreen> createState() => _MobileMemoScreenState();
}

class _MobileMemoScreenState extends State<_MobileMemoScreen> {
  late final TextEditingController _labelController;
  late final TextEditingController _memoController;

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController(text: widget.initialLabel);
    _memoController = TextEditingController(text: widget.initialMemo);
  }

  @override
  void dispose() {
    _labelController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.pop(
      context,
      _MobileMemoResult(
        label: _labelController.text,
        memo: _memoController.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _save();
        }
      },
      child: Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          child: Column(
            children: [
              _MobilePageHeader(
                colors: colors,
                title: 'Splitメモ',
                onClose: _save,
                actions: [
                  _MobileCompactTextButton(
                    colors: colors,
                    label: '保存',
                    prominent: true,
                    onPressed: _save,
                  ),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Split名',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: colors.secondaryText,
                        ),
                      ),
                      const SizedBox(height: 7),
                      TextField(
                        controller: _labelController,
                        maxLines: 1,
                        textInputAction: TextInputAction.done,
                        style: TextStyle(
                          fontSize: 15,
                          color: colors.primaryText,
                        ),
                        decoration: _mobileFieldDecoration(
                          colors,
                          hintText: '作業内容',
                          dense: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        height: 46,
                        padding: const EdgeInsets.symmetric(horizontal: 13),
                        decoration: BoxDecoration(
                          color: colors.control,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.schedule,
                              size: 18,
                              color: colors.secondaryText,
                            ),
                            const SizedBox(width: 9),
                            Text(
                              '経過時間',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.secondaryText,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              widget.elapsedText,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: colors.primaryText,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'メモ',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: colors.secondaryText,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Expanded(
                        child: TextField(
                          key: const ValueKey<String>('mobile-memo-field'),
                          controller: _memoController,
                          expands: true,
                          minLines: null,
                          maxLines: null,
                          textAlignVertical: TextAlignVertical.top,
                          style: TextStyle(
                            color: colors.primaryText,
                            fontSize: 14,
                            height: 1.45,
                          ),
                          decoration: _mobileFieldDecoration(
                            colors,
                            hintText: 'メモを入力',
                          ),
                        ),
                      ),
                    ],
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

class _MobileSummaryResult {
  const _MobileSummaryResult({
    required this.formatId,
    required this.customFormats,
    required this.timeFormat,
  });

  final String formatId;
  final List<SummaryFormatDefinition> customFormats;
  final String timeFormat;
}

class _MobileSummaryScreen extends StatefulWidget {
  const _MobileSummaryScreen({
    required this.colors,
    required this.stopwatch,
    required this.at,
    required this.selectedFormatId,
    required this.customFormats,
    required this.timeFormat,
  });

  final _MobileColors colors;
  final StopwatchController stopwatch;
  final DateTime at;
  final String selectedFormatId;
  final List<SummaryFormatDefinition> customFormats;
  final String timeFormat;

  @override
  State<_MobileSummaryScreen> createState() => _MobileSummaryScreenState();
}

class _MobileSummaryScreenState extends State<_MobileSummaryScreen> {
  late String _formatId;
  late String _timeFormat;
  late List<SummaryFormatDefinition> _customFormats;
  late final TextEditingController _summaryController;

  List<SummaryFormatDefinition> get _formats => [
    ...builtInSummaryFormats,
    ..._customFormats,
  ];

  @override
  void initState() {
    super.initState();
    _formatId = resolveSummaryFormat(
      widget.selectedFormatId,
      widget.customFormats,
    ).id;
    _customFormats = List.of(widget.customFormats);
    _timeFormat = _normalizedSummaryTimeFormat(widget.timeFormat);
    _summaryController = TextEditingController(text: _renderSummary());
  }

  @override
  void dispose() {
    _summaryController.dispose();
    super.dispose();
  }

  String _renderSummary() {
    return _buildSummaryText(
      stopwatch: widget.stopwatch,
      at: widget.at,
      format: resolveSummaryFormat(_formatId, _customFormats),
      timeFormat: _timeFormat,
    );
  }

  void _regenerate() {
    _summaryController.value = TextEditingValue(
      text: _renderSummary(),
      selection: const TextSelection.collapsed(offset: 0),
    );
  }

  void _close() {
    Navigator.pop(
      context,
      _MobileSummaryResult(
        formatId: _formatId,
        customFormats: _customFormats,
        timeFormat: _timeFormat,
      ),
    );
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _summaryController.text));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('サマリーをコピーしました')));
  }

  Future<void> _createCustomFormat() async {
    final result = await Navigator.of(context).push<_MobileFormatEditorResult>(
      MaterialPageRoute(
        builder: (context) => _MobileSummaryFormatEditorScreen(
          colors: widget.colors,
          initialFormat: _createMobileSummaryFormatDraft(_customFormats),
          canDelete: false,
        ),
      ),
    );
    final format = result?.format;
    if (!mounted || format == null) {
      return;
    }
    setState(() {
      _customFormats = _upsertMobileSummaryFormat(_customFormats, format);
      _formatId = format.id;
      _regenerate();
    });
  }

  Future<void> _selectFormat() async {
    final selected = await _showMobileSelectionSheet<String>(
      context: context,
      colors: widget.colors,
      title: 'サマリー表示フォーマット',
      selectedValue: _formatId,
      options: [
        for (final format in _formats)
          _MobileSelectionOption<String>(
            value: format.id,
            label: format.id == templateSummaryFormatId
                ? 'テンプレート'
                : format.name,
            icon: Icons.format_align_left,
          ),
        const _MobileSelectionOption<String>(
          value: '_add',
          label: 'カスタムを追加',
          icon: Icons.add,
        ),
      ],
    );
    if (!mounted || selected == null) {
      return;
    }
    if (selected == '_add') {
      await _createCustomFormat();
      return;
    }
    setState(() {
      _formatId = selected;
      _regenerate();
    });
  }

  Future<void> _selectTimeFormat() async {
    const formats = ['hourMinute', 'decimalHours', 'decimalHoursPrecise'];
    final selected = await _showMobileSelectionSheet<String>(
      context: context,
      colors: widget.colors,
      title: '時間表示形式',
      selectedValue: _timeFormat,
      options: [
        for (final format in formats)
          _MobileSelectionOption<String>(
            value: format,
            label: _summaryTimeOptionLabel(format),
            icon: Icons.schedule,
          ),
      ],
    );
    if (!mounted || selected == null) {
      return;
    }
    setState(() {
      _timeFormat = selected;
      _regenerate();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final selectedFormat = resolveSummaryFormat(_formatId, _customFormats);
    final totalSeconds = widget.stopwatch.elapsedSessionSeconds(at: widget.at);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _close();
        }
      },
      child: Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          child: Column(
            children: [
              _MobilePageHeader(
                colors: colors,
                title: 'サマリー',
                onClose: _close,
                actions: [
                  _MobileUtilityButton(
                    colors: colors,
                    icon: Icons.copy_outlined,
                    tooltip: 'コピー',
                    onPressed: _copy,
                  ),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          _MobileMenuPill(
                            colors: colors,
                            label: selectedFormat.name,
                            tooltip: 'サマリー表示フォーマット',
                            accent: true,
                            onPressed: _selectFormat,
                          ),
                          const SizedBox(width: 6),
                          _MobileMenuPill(
                            colors: colors,
                            label: _formatSummaryDuration(
                              totalSeconds,
                              _timeFormat,
                            ),
                            tooltip: '時間表示形式',
                            onPressed: _selectTimeFormat,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              widget.stopwatch.session?.title ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                color: colors.secondaryText,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: TextField(
                          key: const ValueKey<String>('mobile-summary-field'),
                          controller: _summaryController,
                          expands: true,
                          minLines: null,
                          maxLines: null,
                          textAlignVertical: TextAlignVertical.top,
                          style: TextStyle(
                            color: colors.primaryText,
                            fontSize: 14,
                            height: 1.5,
                          ),
                          decoration: _mobileFieldDecoration(colors),
                        ),
                      ),
                    ],
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

class _MobileSettingsResult {
  const _MobileSettingsResult({
    required this.isMonochrome,
    required this.ringHoursPerCycle,
    required this.defaultSplitMode,
    required this.selectedFormatId,
    required this.customFormats,
    required this.timeFormat,
    this.dataAction,
  });

  final bool isMonochrome;
  final int ringHoursPerCycle;
  final SplitAccumulationMode defaultSplitMode;
  final String selectedFormatId;
  final List<SummaryFormatDefinition> customFormats;
  final String timeFormat;
  final _MobileSettingsDataAction? dataAction;
}

enum _MobileSettingsDataAction {
  importLegacyFile,
  deleteSessionData,
  deleteLapData,
  resetSettings,
  initializeAllData;

  String get title => switch (this) {
    _MobileSettingsDataAction.importLegacyFile => '旧データをインポートしますか？',
    _MobileSettingsDataAction.deleteSessionData => 'セッション情報を削除しますか？',
    _MobileSettingsDataAction.deleteLapData => 'Split情報を削除しますか？',
    _MobileSettingsDataAction.resetSettings => '設定のみ初期化しますか？',
    _MobileSettingsDataAction.initializeAllData => '全データを初期化しますか？',
  };

  String get message => switch (this) {
    _MobileSettingsDataAction.importLegacyFile =>
      '選択したsessions.jsonの内容で、現在のセッションと設定を置き換えます。',
    _MobileSettingsDataAction.deleteSessionData => '全セッション・Split・メモを削除します。',
    _MobileSettingsDataAction.deleteLapData =>
      '全セッションのSplit・メモを削除します。セッション名は保持します。',
    _MobileSettingsDataAction.resetSettings => 'アプリ設定のみをデフォルトに戻します。',
    _MobileSettingsDataAction.initializeAllData => '全データと設定を削除して初期状態に戻します。',
  };

  bool get destructive => switch (this) {
    _MobileSettingsDataAction.importLegacyFile ||
    _MobileSettingsDataAction.resetSettings => false,
    _ => true,
  };

  String get confirmLabel => switch (this) {
    _MobileSettingsDataAction.importLegacyFile => 'ファイルを選択',
    _MobileSettingsDataAction.resetSettings => 'リセット',
    _MobileSettingsDataAction.initializeAllData => '初期化',
    _ => '削除',
  };
}

class _MobileSettingsScreen extends StatefulWidget {
  const _MobileSettingsScreen({
    required this.isMonochrome,
    required this.ringHoursPerCycle,
    required this.defaultSplitMode,
    required this.selectedFormatId,
    required this.customFormats,
    required this.timeFormat,
  });

  final bool isMonochrome;
  final int ringHoursPerCycle;
  final SplitAccumulationMode defaultSplitMode;
  final String selectedFormatId;
  final List<SummaryFormatDefinition> customFormats;
  final String timeFormat;

  @override
  State<_MobileSettingsScreen> createState() => _MobileSettingsScreenState();
}

class _MobileSettingsScreenState extends State<_MobileSettingsScreen> {
  late bool _isMonochrome;
  late int _ringHoursPerCycle;
  late SplitAccumulationMode _defaultSplitMode;
  late String _selectedFormatId;
  late List<SummaryFormatDefinition> _customFormats;
  late String _timeFormat;

  List<SummaryFormatDefinition> get _formats => [
    ...builtInSummaryFormats,
    ..._customFormats,
  ];

  @override
  void initState() {
    super.initState();
    _isMonochrome = widget.isMonochrome;
    _ringHoursPerCycle = widget.ringHoursPerCycle;
    _defaultSplitMode = widget.defaultSplitMode;
    _customFormats = List.of(widget.customFormats);
    _selectedFormatId =
        _formats.any((format) => format.id == widget.selectedFormatId)
        ? widget.selectedFormatId
        : defaultSummaryFormatId;
    _timeFormat = _normalizedSummaryTimeFormat(widget.timeFormat);
  }

  void _close([_MobileSettingsDataAction? dataAction]) {
    Navigator.pop(
      context,
      _MobileSettingsResult(
        isMonochrome: _isMonochrome,
        ringHoursPerCycle: _ringHoursPerCycle,
        defaultSplitMode: _defaultSplitMode,
        selectedFormatId: _selectedFormatId,
        customFormats: _customFormats,
        timeFormat: _timeFormat,
        dataAction: dataAction,
      ),
    );
  }

  Future<void> _addCustomFormat() async {
    await _editCustomFormat(
      _createMobileSummaryFormatDraft(_customFormats),
      canDelete: false,
    );
  }

  Future<void> _editSelectedFormat() async {
    final selected = resolveSummaryFormat(_selectedFormatId, _customFormats);
    if (selected.isBuiltIn) {
      await _addCustomFormat();
      return;
    }
    await _editCustomFormat(selected, canDelete: true);
  }

  Future<void> _editCustomFormat(
    SummaryFormatDefinition format, {
    required bool canDelete,
  }) async {
    final result = await Navigator.of(context).push<_MobileFormatEditorResult>(
      MaterialPageRoute(
        builder: (context) => _MobileSummaryFormatEditorScreen(
          colors: _MobileColors(isMonochrome: _isMonochrome),
          initialFormat: format,
          canDelete: canDelete,
        ),
      ),
    );
    if (!mounted || result == null) {
      return;
    }
    setState(() {
      if (result.deleted) {
        _customFormats = [
          for (final candidate in _customFormats)
            if (candidate.id != format.id) candidate,
        ];
        if (_selectedFormatId == format.id) {
          _selectedFormatId = defaultSummaryFormatId;
        }
      } else if (result.format != null) {
        _customFormats = _upsertMobileSummaryFormat(
          _customFormats,
          result.format!,
        );
        _selectedFormatId = result.format!.id;
      }
    });
  }

  Future<void> _selectSummaryFormat() async {
    final selected = await _showMobileSelectionSheet<String>(
      context: context,
      colors: _MobileColors(isMonochrome: _isMonochrome),
      title: 'サマリー表示フォーマット',
      selectedValue: _selectedFormatId,
      options: [
        for (final format in _formats)
          _MobileSelectionOption<String>(
            value: format.id,
            label: format.id == templateSummaryFormatId
                ? 'テンプレート'
                : format.name,
            icon: Icons.format_align_left,
          ),
        const _MobileSelectionOption<String>(
          value: '_add',
          label: 'カスタムを追加',
          icon: Icons.add,
        ),
      ],
    );
    if (!mounted || selected == null) {
      return;
    }
    if (selected == '_add') {
      await _addCustomFormat();
      return;
    }
    setState(() => _selectedFormatId = selected);
  }

  Future<void> _selectSummaryTimeFormat() async {
    const formats = ['hourMinute', 'decimalHours', 'decimalHoursPrecise'];
    final selected = await _showMobileSelectionSheet<String>(
      context: context,
      colors: _MobileColors(isMonochrome: _isMonochrome),
      title: '時間表示形式',
      selectedValue: _timeFormat,
      options: [
        for (final format in formats)
          _MobileSelectionOption<String>(
            value: format,
            label: _summaryTimeOptionLabel(format),
            icon: Icons.schedule,
          ),
      ],
    );
    if (!mounted || selected == null) {
      return;
    }
    setState(() => _timeFormat = selected);
  }

  Future<void> _requestDataAction(_MobileSettingsDataAction action) async {
    final colors = _MobileColors(isMonochrome: _isMonochrome);
    final confirmed = await _showMobileConfirmationSheet(
      context: context,
      colors: colors,
      title: action.title,
      message: action.message,
      confirmLabel: action.confirmLabel,
      destructive: action.destructive,
    );
    if (confirmed && mounted) {
      _close(action);
    }
  }

  Future<void> _copyContactAddress() async {
    await Clipboard.setData(
      const ClipboardData(text: 'hamachii.project@proton.me'),
    );
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('お問い合わせ先をコピーしました')));
  }

  @override
  Widget build(BuildContext context) {
    final colors = _MobileColors(isMonochrome: _isMonochrome);
    final selectedFormat = resolveSummaryFormat(
      _selectedFormatId,
      _customFormats,
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _close();
        }
      },
      child: Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          child: Column(
            children: [
              _MobilePageHeader(colors: colors, title: '設定', onClose: _close),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
                  children: [
                    _MobileSettingsSection(
                      colors: colors,
                      label: 'テーマカラー',
                      children: [
                        _MobileSettingsRow(
                          colors: colors,
                          title: 'テーマカラー',
                          trailing: SizedBox(
                            width: 148,
                            child: _MobileChoiceBar<bool>(
                              colors: colors,
                              values: const [false, true],
                              labels: const ['カラー', 'モノクロ'],
                              selected: _isMonochrome,
                              onChanged: (value) {
                                setState(() => _isMonochrome = value);
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _MobileSettingsSection(
                      colors: colors,
                      label: '表示',
                      children: [
                        _MobileSettingsRow(
                          colors: colors,
                          title: 'リング周期（1周）',
                          trailing: _MobileStepper(
                            colors: colors,
                            value: '$_ringHoursPerCycle時間',
                            onDecrease: _ringHoursPerCycle > 1
                                ? () => setState(() => _ringHoursPerCycle -= 1)
                                : null,
                            onIncrease: _ringHoursPerCycle < 24
                                ? () => setState(() => _ringHoursPerCycle += 1)
                                : null,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _MobileSettingsRow(
                          colors: colors,
                          title: 'デフォルト分配モード',
                          subtitle: '新しく追加するセッションの初期値',
                          trailing: SizedBox(
                            width: 148,
                            child: _MobileChoiceBar<SplitAccumulationMode>(
                              colors: colors,
                              values: const [
                                SplitAccumulationMode.radio,
                                SplitAccumulationMode.checkbox,
                              ],
                              labels: const ['ラジオ', 'チェック'],
                              selected: _defaultSplitMode,
                              onChanged: (value) {
                                setState(() => _defaultSplitMode = value);
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _MobileSettingsSection(
                      colors: colors,
                      label: 'サマリー表示',
                      children: [
                        _MobileSettingsRow(
                          colors: colors,
                          title: 'サマリー表示フォーマット',
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _MobileMenuPill(
                                colors: colors,
                                label: selectedFormat.name,
                                tooltip: '表示フォーマットを選択',
                                onPressed: _selectSummaryFormat,
                              ),
                              const SizedBox(width: 5),
                              _MobileUtilityButton(
                                colors: colors,
                                icon: selectedFormat.isBuiltIn
                                    ? Icons.add
                                    : Icons.edit_outlined,
                                tooltip: selectedFormat.isBuiltIn
                                    ? 'カスタムを追加'
                                    : 'カスタムを編集',
                                onPressed: _editSelectedFormat,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        _MobileSettingsRow(
                          colors: colors,
                          title: '時間表示形式',
                          trailing: _MobileMenuPill(
                            colors: colors,
                            label: _summaryTimeOptionLabel(_timeFormat),
                            tooltip: '時間表示形式を選択',
                            onPressed: _selectSummaryTimeFormat,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _MobileSettingsSection(
                      colors: colors,
                      label: '案内',
                      children: [
                        _MobileSettingsActionRow(
                          colors: colors,
                          title: '操作説明',
                          icon: Icons.question_mark,
                          onPressed: () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (context) =>
                                  _MobileGuideScreen(colors: colors),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        _MobileSettingsActionRow(
                          colors: colors,
                          title: 'お問い合わせ先をコピー',
                          icon: Icons.mail_outline,
                          onPressed: _copyContactAddress,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _MobileSettingsSection(
                      colors: colors,
                      label: 'データ管理',
                      children: [
                        _MobileSettingsActionRow(
                          colors: colors,
                          title: 'sessions.jsonを選択',
                          icon: Icons.folder_open,
                          onPressed: () => _requestDataAction(
                            _MobileSettingsDataAction.importLegacyFile,
                          ),
                        ),
                        const SizedBox(height: 6),
                        _MobileSettingsActionRow(
                          colors: colors,
                          title: 'セッション情報',
                          icon: Icons.delete_outline,
                          destructive: true,
                          onPressed: () => _requestDataAction(
                            _MobileSettingsDataAction.deleteSessionData,
                          ),
                        ),
                        const SizedBox(height: 6),
                        _MobileSettingsActionRow(
                          colors: colors,
                          title: 'Split情報',
                          icon: Icons.delete_outline,
                          destructive: true,
                          onPressed: () => _requestDataAction(
                            _MobileSettingsDataAction.deleteLapData,
                          ),
                        ),
                        const SizedBox(height: 6),
                        _MobileSettingsActionRow(
                          colors: colors,
                          title: '設定のみ初期化',
                          icon: Icons.refresh,
                          onPressed: () => _requestDataAction(
                            _MobileSettingsDataAction.resetSettings,
                          ),
                        ),
                        const SizedBox(height: 6),
                        _MobileSettingsActionRow(
                          colors: colors,
                          title: '全データ初期化',
                          icon: Icons.warning_amber,
                          destructive: true,
                          onPressed: () => _requestDataAction(
                            _MobileSettingsDataAction.initializeAllData,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'セッションと設定はこの端末内に保存されます。端末間の自動同期は行いません。',
                      style: TextStyle(
                        color: colors.secondaryText,
                        fontSize: 10,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileSettingsSection extends StatelessWidget {
  const _MobileSettingsSection({
    required this.colors,
    required this.label,
    required this.children,
  });

  final _MobileColors colors;
  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(
            label,
            style: TextStyle(
              color: colors.secondaryText,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.section,
            border: Border.all(color: colors.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _MobileSettingsRow extends StatelessWidget {
  const _MobileSettingsRow({
    required this.colors,
    required this.title,
    required this.trailing,
    this.subtitle,
  });

  final _MobileColors colors;
  final String title;
  final String? subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: colors.primaryText,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  style: TextStyle(color: colors.secondaryText, fontSize: 10),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 10),
        trailing,
      ],
    );
  }
}

class _MobileChoiceBar<T> extends StatelessWidget {
  const _MobileChoiceBar({
    required this.colors,
    required this.values,
    required this.labels,
    required this.selected,
    required this.onChanged,
  });

  final _MobileColors colors;
  final List<T> values;
  final List<String> labels;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colors.headerControl,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        children: [
          for (var index = 0; index < values.length; index += 1)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => onChanged(values[index]),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: values[index] == selected
                        ? colors.selectedChip
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    labels[index],
                    style: TextStyle(
                      color: colors.primaryText,
                      fontSize: 11,
                      fontWeight: values[index] == selected
                          ? FontWeight.w600
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

class _MobileStepper extends StatelessWidget {
  const _MobileStepper({
    required this.colors,
    required this.value,
    required this.onDecrease,
    required this.onIncrease,
  });

  final _MobileColors colors;
  final String value;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: colors.buttonBackground,
        border: Border.all(color: colors.buttonBorder),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _button(Icons.remove, onDecrease),
          SizedBox(
            width: 58,
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.primaryText, fontSize: 11),
            ),
          ),
          _button(Icons.add, onIncrease),
        ],
      ),
    );
  }

  Widget _button(IconData icon, VoidCallback? onPressed) {
    return InkWell(
      onTap: onPressed,
      child: SizedBox(
        width: 42,
        height: 42,
        child: Icon(
          icon,
          size: 15,
          color: onPressed == null ? colors.softText : colors.utility,
        ),
      ),
    );
  }
}

class _MobileSettingsActionRow extends StatelessWidget {
  const _MobileSettingsActionRow({
    required this.colors,
    required this.title,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
  });

  final _MobileColors colors;
  final String title;
  final IconData icon;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? colors.danger : colors.primaryText;
    return Material(
      color: colors.buttonBackground,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border.all(color: colors.buttonBorder),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(icon, size: 19, color: color),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 19, color: colors.secondaryText),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileFormatEditorResult {
  const _MobileFormatEditorResult({this.format, this.deleted = false});

  final SummaryFormatDefinition? format;
  final bool deleted;
}

class _MobileSummaryFormatEditorScreen extends StatefulWidget {
  const _MobileSummaryFormatEditorScreen({
    required this.colors,
    required this.initialFormat,
    required this.canDelete,
  });

  final _MobileColors colors;
  final SummaryFormatDefinition initialFormat;
  final bool canDelete;

  @override
  State<_MobileSummaryFormatEditorScreen> createState() =>
      _MobileSummaryFormatEditorScreenState();
}

class _MobileSummaryFormatEditorScreenState
    extends State<_MobileSummaryFormatEditorScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _titleController;
  late final TextEditingController _timeController;
  late final TextEditingController _memoController;
  late final TextEditingController _exampleTitleController;
  late final TextEditingController _exampleTimeController;
  late final TextEditingController _exampleMemoController;
  final List<_MobileRuleControllers> _rules = [];
  var _selectedPage = 0;
  var _nextRuleNumber = 0;

  @override
  void initState() {
    super.initState();
    _nameController = _controller(widget.initialFormat.name);
    _titleController = _controller(widget.initialFormat.titleTemplate);
    _timeController = _controller(widget.initialFormat.timeTemplate);
    _memoController = _controller(widget.initialFormat.memoTemplate);
    _exampleTitleController = _controller('資料作成');
    _exampleTimeController = _controller('1.10h');
    _exampleMemoController = _controller(
      '午前中に資料を作成しました。\\n確認事項を整理しました。\n'
      '午後は打ち合わせ内容をまとめます。',
    );
    for (final rule in widget.initialFormat.rules) {
      _rules.add(_createRuleControllers(rule));
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _titleController.dispose();
    _timeController.dispose();
    _memoController.dispose();
    _exampleTitleController.dispose();
    _exampleTimeController.dispose();
    _exampleMemoController.dispose();
    for (final rule in _rules) {
      rule.dispose();
    }
    super.dispose();
  }

  TextEditingController _controller(String text) {
    final controller = TextEditingController(
      text: _mobileEncodeVisibleWhitespace(text),
    );
    controller.addListener(_refresh);
    return controller;
  }

  _MobileRuleControllers _createRuleControllers(SummaryReplacementRule rule) {
    _nextRuleNumber += 1;
    return _MobileRuleControllers(
      id: rule.id.isEmpty
          ? 'rule-${DateTime.now().microsecondsSinceEpoch}-$_nextRuleNumber'
          : rule.id,
      matchController: _controller(rule.match),
      replacementController: _controller(rule.replacement),
    );
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  SummaryFormatDefinition get _draft {
    final name = _mobileDecodeVisibleWhitespace(_nameController.text).trim();
    return widget.initialFormat.copyWith(
      name: name.isEmpty ? widget.initialFormat.name : name,
      titleTemplate: _mobileDecodeVisibleWhitespace(_titleController.text),
      timeTemplate: _mobileDecodeVisibleWhitespace(_timeController.text),
      memoTemplate: _mobileDecodeVisibleWhitespace(_memoController.text),
      rules: [
        for (final rule in _rules)
          SummaryReplacementRule(
            id: rule.id,
            match: _mobileDecodeVisibleWhitespace(rule.matchController.text),
            replacement: _mobileDecodeVisibleWhitespace(
              rule.replacementController.text,
            ),
          ),
      ],
    );
  }

  String get _preview => renderSummaryEntry(
    format: _draft,
    title: _mobileDecodeVisibleWhitespace(_exampleTitleController.text),
    time: _mobileDecodeVisibleWhitespace(_exampleTimeController.text),
    memo: _mobileDecodeVisibleWhitespace(_exampleMemoController.text),
  );

  void _save() {
    Navigator.pop(context, _MobileFormatEditorResult(format: _draft));
  }

  Future<void> _delete() async {
    final confirmed = await _showMobileConfirmationSheet(
      context: context,
      colors: widget.colors,
      title: '${widget.initialFormat.name}を削除しますか？',
      message: 'このカスタムフォーマットと置換ルールを削除します。',
      confirmLabel: '削除',
      destructive: true,
    );
    if (confirmed && mounted) {
      Navigator.pop(context, const _MobileFormatEditorResult(deleted: true));
    }
  }

  void _addRule() {
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    setState(() {
      _rules.add(
        _createRuleControllers(
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
    final rule = _rules.removeAt(index);
    rule.dispose();
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

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          children: [
            _MobilePageHeader(
              colors: colors,
              title: 'カスタムフォーマット',
              onClose: () => Navigator.pop(context),
              actions: [
                _MobileCompactTextButton(
                  colors: colors,
                  label: '保存',
                  prominent: true,
                  onPressed: _save,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: Column(
                children: [
                  _MobileChoiceBar<int>(
                    colors: colors,
                    values: const [0, 1],
                    labels: const ['入力例とプレビュー', '表示形式とルール'],
                    selected: _selectedPage,
                    onChanged: (value) => setState(() => _selectedPage = value),
                  ),
                  const SizedBox(height: 7),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '␣ 半角スペース　□ 全角スペース',
                      style: TextStyle(
                        color: colors.secondaryText,
                        fontSize: 9,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _selectedPage,
                children: [_buildPreviewPage(colors), _buildEditorPage(colors)],
              ),
            ),
            if (widget.canDelete)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 7, 14, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _delete,
                    icon: const Icon(Icons.delete_outline, size: 15),
                    label: const Text('このカスタムを削除'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFC94848),
                      side: const BorderSide(color: Color(0x66C94848)),
                      textStyle: const TextStyle(fontSize: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewPage(_MobileColors colors) {
    return ListView(
      key: const ValueKey<String>('mobile-format-preview-page'),
      padding: const EdgeInsets.fromLTRB(14, 3, 14, 18),
      children: [
        _MobileFormatHeading(
          colors: colors,
          icon: Icons.edit_outlined,
          label: '入力例',
        ),
        const SizedBox(height: 7),
        _MobileFormatField(
          colors: colors,
          controller: _exampleTitleController,
          label: 'Split名',
          fieldKey: const ValueKey<String>('mobile-format-example-title'),
        ),
        const SizedBox(height: 8),
        _MobileFormatField(
          colors: colors,
          controller: _exampleTimeController,
          label: '作業時間',
          fieldKey: const ValueKey<String>('mobile-format-example-time'),
        ),
        const SizedBox(height: 8),
        _MobileFormatField(
          colors: colors,
          controller: _exampleMemoController,
          label: 'メモ',
          maxLines: 4,
          fieldKey: const ValueKey<String>('mobile-format-example-memo'),
        ),
        const SizedBox(height: 14),
        _MobileFormatHeading(
          colors: colors,
          icon: Icons.visibility_outlined,
          label: 'サマリープレビュー',
        ),
        const SizedBox(height: 7),
        Container(
          key: const ValueKey<String>('mobile-format-preview'),
          constraints: const BoxConstraints(minHeight: 150),
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(11, 10, 10, 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.82),
            border: Border(
              left: BorderSide(
                color: colors.accent.withValues(alpha: 0.72),
                width: 2,
              ),
            ),
          ),
          child: SelectableText(
            _preview,
            style: TextStyle(
              color: colors.primaryText,
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEditorPage(_MobileColors colors) {
    return ListView(
      key: const ValueKey<String>('mobile-format-editor-page'),
      padding: const EdgeInsets.fromLTRB(14, 3, 14, 18),
      children: [
        _MobileFormatHeading(colors: colors, icon: Icons.tune, label: '表示形式'),
        const SizedBox(height: 7),
        _MobileFormatField(
          colors: colors,
          controller: _nameController,
          label: 'フォーマット名',
          fieldKey: const ValueKey<String>('mobile-format-name-field'),
        ),
        const SizedBox(height: 8),
        _MobileFormatField(
          colors: colors,
          controller: _titleController,
          label: 'タイトル表示',
          token: '{title}',
          maxLines: 3,
          fieldKey: const ValueKey<String>('mobile-format-title-field'),
        ),
        const SizedBox(height: 8),
        _MobileFormatField(
          colors: colors,
          controller: _timeController,
          label: '作業時間表示',
          token: '{time}',
          maxLines: 3,
          fieldKey: const ValueKey<String>('mobile-format-time-field'),
        ),
        const SizedBox(height: 8),
        _MobileFormatField(
          colors: colors,
          controller: _memoController,
          label: 'メモ表示',
          token: '{memo}',
          maxLines: 3,
          fieldKey: const ValueKey<String>('mobile-format-memo-field'),
        ),
        const SizedBox(height: 14),
        _MobileFormatHeading(
          colors: colors,
          icon: Icons.find_replace,
          label: '置換ルール',
          trailing: _MobileTokenButton(
            colors: colors,
            label: 'ルール',
            onPressed: _addRule,
          ),
        ),
        const SizedBox(height: 7),
        if (_rules.isEmpty)
          Text(
            'ルールなし',
            style: TextStyle(color: colors.secondaryText, fontSize: 10),
          ),
        for (var index = 0; index < _rules.length; index += 1) ...[
          _buildRule(colors, index),
          if (index != _rules.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _buildRule(_MobileColors colors, int index) {
    final rule = _rules[index];
    return Container(
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: colors.section,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                'ルール ${index + 1}',
                style: TextStyle(
                  color: colors.primaryText,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _MobileMiniIconButton(
                colors: colors,
                icon: Icons.keyboard_arrow_up,
                enabled: index > 0,
                onPressed: () => _moveRule(index, -1),
              ),
              _MobileMiniIconButton(
                colors: colors,
                icon: Icons.keyboard_arrow_down,
                enabled: index < _rules.length - 1,
                onPressed: () => _moveRule(index, 1),
              ),
              _MobileMiniIconButton(
                colors: colors,
                icon: Icons.delete_outline,
                destructive: true,
                onPressed: () => _removeRule(index),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _MobileFormatField(
            colors: colors,
            controller: rule.matchController,
            label: '検索文字列',
            maxLines: 3,
          ),
          const SizedBox(height: 7),
          _MobileFormatField(
            colors: colors,
            controller: rule.replacementController,
            label: '置換文字列',
            token: '{match}',
            maxLines: 3,
          ),
        ],
      ),
    );
  }
}

class _MobileRuleControllers {
  const _MobileRuleControllers({
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

class _MobileFormatHeading extends StatelessWidget {
  const _MobileFormatHeading({
    required this.colors,
    required this.icon,
    required this.label,
    this.trailing,
  });

  final _MobileColors colors;
  final IconData icon;
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 13, color: colors.accent),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            color: colors.primaryText,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (trailing != null) ...[const Spacer(), trailing!],
      ],
    );
  }
}

class _MobileFormatField extends StatelessWidget {
  const _MobileFormatField({
    required this.colors,
    required this.controller,
    required this.label,
    this.token,
    this.maxLines = 1,
    this.fieldKey,
  });

  final _MobileColors colors;
  final TextEditingController controller;
  final String label;
  final String? token;
  final int maxLines;
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
              style: TextStyle(color: colors.secondaryText, fontSize: 10),
            ),
            if (token != null) ...[
              const Spacer(),
              _MobileTokenButton(
                colors: colors,
                label: token!,
                onPressed: () => _mobileInsertToken(controller, token!),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        TextField(
          key: fieldKey,
          controller: controller,
          minLines: 1,
          maxLines: maxLines,
          textInputAction: maxLines == 1
              ? TextInputAction.done
              : TextInputAction.newline,
          inputFormatters: const [_MobileVisibleWhitespaceFormatter()],
          style: TextStyle(
            color: colors.primaryText,
            fontSize: 11,
            height: 1.3,
          ),
          decoration: _mobileFieldDecoration(colors, dense: true),
        ),
      ],
    );
  }
}

class _MobileTokenButton extends StatelessWidget {
  const _MobileTokenButton({
    required this.colors,
    required this.label,
    required this.onPressed,
  });

  final _MobileColors colors;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.accent.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onPressed,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: colors.accent.withValues(alpha: 0.42)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 10, color: colors.accent),
              const SizedBox(width: 2),
              Text(
                label,
                style: TextStyle(
                  color: colors.accent,
                  fontSize: 10,
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

class _MobileMiniIconButton extends StatelessWidget {
  const _MobileMiniIconButton({
    required this.colors,
    required this.icon,
    required this.onPressed,
    this.enabled = true,
    this.destructive = false,
  });

  final _MobileColors colors;
  final IconData icon;
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
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: enabled ? onPressed : null,
      child: SizedBox(
        width: 36,
        height: 36,
        child: Icon(icon, size: 17, color: color),
      ),
    );
  }
}

class _MobileVisibleWhitespaceFormatter extends TextInputFormatter {
  const _MobileVisibleWhitespaceFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final encoded = _mobileEncodeVisibleWhitespace(newValue.text);
    if (encoded == newValue.text) {
      return newValue;
    }
    return newValue.copyWith(text: encoded);
  }
}

String _mobileEncodeVisibleWhitespace(String value) {
  return value
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('　', '□')
      .replaceAll(' ', '␣');
}

String _mobileDecodeVisibleWhitespace(String value) {
  return value.replaceAll('␣', ' ').replaceAll('□', '　');
}

void _mobileInsertToken(TextEditingController controller, String token) {
  final selection = controller.selection;
  final start = selection.isValid ? selection.start : controller.text.length;
  final end = selection.isValid ? selection.end : controller.text.length;
  controller.value = TextEditingValue(
    text: controller.text.replaceRange(start, end, token),
    selection: TextSelection.collapsed(offset: start + token.length),
  );
}

class _MobileTimelinePainter extends CustomPainter {
  const _MobileTimelinePainter({
    required this.colors,
    required this.laps,
    required this.lapSeconds,
    required this.totalSeconds,
    required this.ringHoursPerCycle,
  });

  final _MobileColors colors;
  final List<WorkLap> laps;
  final Map<String, int> lapSeconds;
  final int totalSeconds;
  final int ringHoursPerCycle;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final cycleSeconds = math.max(1, ringHoursPerCycle) * 3600;
    final showOuter = totalSeconds >= cycleSeconds;
    const strokeWidth = 20.0;
    final outerRadius = math.min(size.width, size.height) / 2 - 12;
    final innerRadius = showOuter
        ? math.max(12.0, outerRadius - strokeWidth - 4)
        : outerRadius;
    final ranges = <_MobileLapRange>[];
    var cursor = 0;
    for (final lap in laps) {
      final seconds = lapSeconds[lap.id] ?? lap.accumulatedSeconds;
      ranges.add(_MobileLapRange(lap, cursor, cursor + seconds));
      cursor += seconds;
    }

    if (showOuter) {
      final currentStart = (totalSeconds ~/ cycleSeconds) * cycleSeconds;
      _drawRing(
        canvas,
        center,
        outerRadius,
        strokeWidth,
        currentStart,
        currentStart + cycleSeconds,
        ranges,
      );
      _drawRing(
        canvas,
        center,
        innerRadius,
        strokeWidth,
        currentStart - cycleSeconds,
        currentStart,
        ranges,
      );
    } else {
      _drawRing(
        canvas,
        center,
        innerRadius,
        strokeWidth,
        0,
        cycleSeconds,
        ranges,
      );
    }
  }

  void _drawRing(
    Canvas canvas,
    Offset center,
    double radius,
    double strokeWidth,
    int windowStart,
    int windowEnd,
    List<_MobileLapRange> ranges,
  ) {
    final trackPaint = Paint()
      ..color = colors.track
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, trackPaint);

    final rect = Rect.fromCircle(center: center, radius: radius);
    final windowSeconds = math.max(1, windowEnd - windowStart);
    final boundaries = <double>[];
    for (final range in ranges) {
      final start = math.max(range.start, windowStart);
      final end = math.min(range.end, windowEnd);
      if (end <= start) {
        continue;
      }
      final startRatio = (start - windowStart) / windowSeconds;
      final endRatio = (end - windowStart) / windowSeconds;
      final paint = Paint()
        ..color = colors.lapColor(range.lap.index)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(
        rect,
        -math.pi / 2 + (math.pi * 2 * startRatio),
        math.pi * 2 * (endRatio - startRatio),
        false,
        paint,
      );
      if (startRatio > 0) {
        boundaries.add(startRatio);
      }
    }

    final borderPaint = Paint()
      ..color = colors.ringBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, radius + strokeWidth / 2 + 1, borderPaint);
    canvas.drawCircle(
      center,
      math.max(0, radius - strokeWidth / 2 - 1),
      borderPaint,
    );
    for (final ratio in boundaries) {
      final angle = -math.pi / 2 + (math.pi * 2 * ratio);
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + direction * (radius - strokeWidth / 2),
        center + direction * (radius + strokeWidth / 2),
        Paint()
          ..color = colors.ringBorder
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MobileTimelinePainter oldDelegate) {
    return oldDelegate.colors != colors ||
        oldDelegate.laps != laps ||
        oldDelegate.lapSeconds != lapSeconds ||
        oldDelegate.totalSeconds != totalSeconds ||
        oldDelegate.ringHoursPerCycle != ringHoursPerCycle;
  }
}

class _MobileLapRange {
  const _MobileLapRange(this.lap, this.start, this.end);

  final WorkLap lap;
  final int start;
  final int end;
}

class _MobileColors {
  const _MobileColors({required this.isMonochrome});

  final bool isMonochrome;

  Color get background =>
      isMonochrome ? const Color(0xFFF3F3F4) : const Color(0xFFF5F7FA);
  Color get surface =>
      isMonochrome ? const Color(0xFFFAFAFA) : const Color(0xFFFFFFFF);
  Color get section => surface;
  Color get lapCard => surface;
  Color get control =>
      isMonochrome ? const Color(0xFFEDEDEF) : const Color(0xFFEEF2F6);
  Color get primaryText => const Color(0xFF171A21);
  Color get secondaryText => const Color(0xFF667085);
  Color get softText => const Color(0xFFA8B0BD);
  Color get utility => const Color(0xFF475467);
  Color get accent =>
      isMonochrome ? const Color(0xFF35383F) : const Color(0xFF2563EB);
  Color get accentSoft =>
      isMonochrome ? const Color(0xFFE1E2E4) : const Color(0xFFE8F0FF);
  Color get border =>
      isMonochrome ? const Color(0xFFD5D5D8) : const Color(0xFFE1E5EA);
  Color get strongBorder =>
      isMonochrome ? const Color(0xFFB8B9BD) : const Color(0xFFCBD2DA);
  Color get headerControl =>
      isMonochrome ? const Color(0xFFEDEDEF) : const Color(0xFFF1F4F7);
  Color get selectedChip =>
      isMonochrome ? const Color(0xFFDADADD) : const Color(0xFFFFFFFF);
  Color get selectedRow =>
      isMonochrome ? const Color(0xFFE9E9EB) : const Color(0xFFEFF5FF);
  Color get buttonBackground =>
      isMonochrome ? const Color(0xFFEDEDEF) : const Color(0xFFF2F4F7);
  Color get buttonBorder =>
      isMonochrome ? const Color(0xFFC8C9CD) : const Color(0xFFD7DCE2);
  Color get track =>
      isMonochrome ? const Color(0xFFE2E2E4) : const Color(0xFFE6E9EE);
  Color get ringBorder => Colors.white;
  Color get danger => const Color(0xFFD14343);
  Color get dangerSoft => const Color(0xFFFDECEC);

  Color lapColor(int index) {
    if (isMonochrome) {
      const values = [
        Color(0xFF34363B),
        Color(0xFF53565D),
        Color(0xFF71757D),
        Color(0xFF90949B),
        Color(0xFFAFB2B7),
      ];
      return values[math.max(0, index - 1) % values.length];
    }
    const values = [
      Color(0xFFE5484D),
      Color(0xFFF97316),
      Color(0xFFE59F00),
      Color(0xFF84CC16),
      Color(0xFF22C55E),
      Color(0xFF10B981),
      Color(0xFF14B8A6),
      Color(0xFF06B6D4),
      Color(0xFF0EA5E9),
      Color(0xFF3B82F6),
      Color(0xFF6366F1),
      Color(0xFF8B5CF6),
      Color(0xFFA855F7),
      Color(0xFFD946EF),
      Color(0xFFEC4899),
      Color(0xFFF43F5E),
    ];
    return values[math.max(0, index - 1) % values.length];
  }

  @override
  bool operator ==(Object other) =>
      other is _MobileColors && other.isMonochrome == isMonochrome;

  @override
  int get hashCode => isMonochrome.hashCode;
}

StopwatchSnapshot _emptySessionSnapshot(
  DateTime now,
  String title, {
  required SplitAccumulationMode splitMode,
}) {
  return StopwatchSnapshot(
    session: WorkSession(
      id: 'session-${now.microsecondsSinceEpoch}',
      title: title,
      startedAt: now,
    ),
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

String _dateTitle(DateTime date) => '${date.year}/${date.month}/${date.day}';

String _nextSessionTitle(DateTime date, List<String> existingTitles) {
  final base = _dateTitle(date);
  if (!existingTitles.contains(base)) {
    return base;
  }
  var suffix = 2;
  while (existingTitles.contains('$base ($suffix)')) {
    suffix += 1;
  }
  return '$base ($suffix)';
}

String _formatDuration(int seconds) {
  final safeSeconds = math.max(0, seconds);
  final hours = safeSeconds ~/ 3600;
  final minutes = (safeSeconds % 3600) ~/ 60;
  final remainingSeconds = safeSeconds % 60;
  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}:'
      '${remainingSeconds.toString().padLeft(2, '0')}';
}

String _normalizedSummaryTimeFormat(String value) {
  return switch (value) {
    'decimalHoursPrecise' || 'hourMinute' => value,
    _ => 'decimalHours',
  };
}

String _summaryTimeOptionLabel(String value) {
  return switch (_normalizedSummaryTimeFormat(value)) {
    'hourMinute' => '時間',
    'decimalHoursPrecise' => 'h（小数第2位まで）',
    _ => 'h（小数第1位まで）',
  };
}

InputDecoration _mobileFieldDecoration(
  _MobileColors colors, {
  String? hintText,
  bool dense = false,
}) {
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(color: colors.border),
  );
  return InputDecoration(
    isDense: dense,
    filled: true,
    fillColor: colors.surface,
    hintText: hintText,
    hintStyle: TextStyle(color: colors.secondaryText, fontSize: 13),
    contentPadding: dense
        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 11)
        : const EdgeInsets.all(14),
    border: border,
    enabledBorder: border,
    focusedBorder: border,
  );
}

String _formatSummaryDuration(int seconds, String format) {
  final safeSeconds = math.max(0, seconds);
  return switch (_normalizedSummaryTimeFormat(format)) {
    'decimalHoursPrecise' => '${(safeSeconds / 3600).toStringAsFixed(2)}h',
    'hourMinute' => () {
      final totalMinutes = (safeSeconds + 30) ~/ 60;
      return '${totalMinutes ~/ 60}時間${totalMinutes % 60}分';
    }(),
    _ => '${(safeSeconds / 3600).toStringAsFixed(1)}h',
  };
}

String _buildSummaryText({
  required StopwatchController stopwatch,
  required DateTime at,
  required SummaryFormatDefinition format,
  required String timeFormat,
}) {
  if (stopwatch.laps.isEmpty) {
    return 'Splitはまだありません';
  }
  final lapSeconds = stopwatch.displayedLapSecondsMap(at: at);
  return [
    for (final lap in stopwatch.laps)
      renderSummaryEntry(
        format: format,
        title: lap.label,
        time: _formatSummaryDuration(
          lapSeconds[lap.id] ?? lap.accumulatedSeconds,
          timeFormat,
        ),
        memo: lap.memo,
      ),
  ].where((entry) => entry.isNotEmpty).join('\n');
}
