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
    return showDialog<String>(
      context: context,
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

  Future<void> _openHelp() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => _MobileGuideScreen(
          colors: _MobileColors(isMonochrome: _isMonochrome),
        ),
      ),
    );
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
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: colors.background,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: colors.border),
            ),
            title: Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            content: Text(message, style: const TextStyle(fontSize: 12)),
            actions: [
              _MobileCompactTextButton(
                colors: colors,
                label: 'キャンセル',
                onPressed: () => Navigator.pop(context, false),
              ),
              _MobileCompactTextButton(
                colors: colors,
                label: confirmLabel,
                prominent: !destructive,
                destructive: destructive,
                onPressed: () => Navigator.pop(context, true),
              ),
            ],
          ),
        ) ??
        false;
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
              onOpenHelp: _openHelp,
              onAddSession: _addSession,
              onOpenSettings: _openSettings,
            ),
            Divider(height: 1, color: colors.border),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: _MobileSessionOverview(
                      colors: colors,
                      sessionTitle:
                          _stopwatch.session?.title ?? _dateTitle(_clock),
                      stateLabel: _stateLabel,
                      totalSeconds: _totalSeconds,
                      ringHoursPerCycle: _ringHoursPerCycle,
                      laps: _stopwatch.laps,
                      lapSeconds: lapSeconds,
                      onEditTitle: _editSessionTitle,
                      onEditRingCycle: _openSettings,
                      onOpenSummary: _openSummary,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _MobileSplitSectionHeader(
                      colors: colors,
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
    required this.onOpenHelp,
    required this.onAddSession,
    required this.onOpenSettings,
  });

  final _MobileColors colors;
  final List<String> sessions;
  final int selectedSessionIndex;
  final ValueChanged<int> onSelectSession;
  final VoidCallback onOpenHelp;
  final VoidCallback onAddSession;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            Icon(Icons.timer_outlined, size: 17, color: colors.primaryText),
            const SizedBox(width: 5),
            Text(
              'SplitLog',
              style: TextStyle(
                color: colors.primaryText,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            _MobileCircleIconButton(
              icon: Icons.question_mark,
              tooltip: '使い方',
              colors: colors,
              size: 24,
              iconSize: 11,
              onPressed: onOpenHelp,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: PopupMenuButton<int>(
                key: const ValueKey<String>('mobile-session-menu'),
                tooltip: 'セッションを切り替え',
                onSelected: onSelectSession,
                itemBuilder: (context) => [
                  for (var index = 0; index < sessions.length; index += 1)
                    PopupMenuItem<int>(
                      value: index,
                      height: 36,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 20,
                            child: index == selectedSessionIndex
                                ? Icon(
                                    Icons.check,
                                    size: 17,
                                    color: colors.accent,
                                  )
                                : null,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              sessions[index],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                child: Container(
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: colors.headerControl,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: colors.strongBorder),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          sessions[selectedSessionIndex],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.primaryText,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.arrow_drop_down,
                        size: 18,
                        color: colors.secondaryText,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 7),
            _MobileCircleIconButton(
              colors: colors,
              tooltip: 'セッションを追加',
              icon: Icons.add,
              onPressed: onAddSession,
            ),
            const SizedBox(width: 7),
            _MobileCircleIconButton(
              colors: colors,
              tooltip: '設定',
              icon: Icons.settings_outlined,
              onPressed: onOpenSettings,
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileSessionOverview extends StatelessWidget {
  const _MobileSessionOverview({
    required this.colors,
    required this.sessionTitle,
    required this.stateLabel,
    required this.totalSeconds,
    required this.ringHoursPerCycle,
    required this.laps,
    required this.lapSeconds,
    required this.onEditTitle,
    required this.onEditRingCycle,
    required this.onOpenSummary,
  });

  final _MobileColors colors;
  final String sessionTitle;
  final String stateLabel;
  final int totalSeconds;
  final int ringHoursPerCycle;
  final List<WorkLap> laps;
  final Map<String, int> lapSeconds;
  final VoidCallback onEditTitle;
  final VoidCallback onEditRingCycle;
  final VoidCallback onOpenSummary;

  @override
  Widget build(BuildContext context) {
    final hasOuterRing = totalSeconds >= ringHoursPerCycle * 3600;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  key: const ValueKey<String>('mobile-session-title-editor'),
                  borderRadius: BorderRadius.circular(5),
                  onTap: onEditTitle,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: _MobileSessionTitle(
                      colors: colors,
                      title: sessionTitle,
                    ),
                  ),
                ),
              ),
              _MobileSmallPill(
                colors: colors,
                label: '全体経過 ${_formatDuration(totalSeconds)}',
              ),
              const SizedBox(width: 6),
              _MobileUtilityButton(
                colors: colors,
                tooltip: 'サマリー',
                icon: Icons.description_outlined,
                onPressed: onOpenSummary,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            height: 180,
            width: double.infinity,
            decoration: BoxDecoration(
              color: colors.section,
              border: Border.all(color: colors.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(
              children: [
                Positioned(
                  top: 9,
                  left: 11,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(5),
                    onTap: onEditRingCycle,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: Text(
                        '↻ ${ringHoursPerCycle}h',
                        style: TextStyle(
                          color: colors.secondaryText,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),
                ),
                Center(
                  child: SizedBox(
                    width: 166,
                    height: 166,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CustomPaint(
                          size: const Size.square(166),
                          painter: _MobileTimelinePainter(
                            colors: colors,
                            laps: laps,
                            lapSeconds: lapSeconds,
                            totalSeconds: totalSeconds,
                            ringHoursPerCycle: ringHoursPerCycle,
                          ),
                        ),
                        SizedBox(
                          width: hasOuterRing ? 74 : 112,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
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
                                    fontSize: 19,
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                stateLabel,
                                style: TextStyle(
                                  color: colors.secondaryText,
                                  fontSize: 10,
                                ),
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
        ],
      ),
    );
  }
}

class _MobileSplitSectionHeader extends StatelessWidget {
  const _MobileSplitSectionHeader({
    required this.colors,
    required this.mode,
    required this.onModeChanged,
  });

  final _MobileColors colors;
  final SplitAccumulationMode mode;
  final ValueChanged<SplitAccumulationMode> onModeChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.fromLTRB(12, 6, 10, 6),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.symmetric(horizontal: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Split',
              style: TextStyle(
                color: colors.primaryText,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Material(
        color: selected ? colors.selectedRow : colors.lapCard,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onActivate,
          child: Container(
            constraints: const BoxConstraints(minHeight: 54),
            padding: const EdgeInsets.fromLTRB(6, 4, 5, 3),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: colors.lapColor(lap.index), width: 2),
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  height: 44,
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
                      size: 18,
                      color: selected || active
                          ? colors.utility
                          : colors.secondaryText,
                    ),
                  ),
                ),
                Expanded(
                  child: InkWell(
                    key: ValueKey<String>('mobile-lap-label-${lap.id}'),
                    borderRadius: BorderRadius.circular(5),
                    onTap: onEditLabel,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 5,
                      ),
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
                              fontSize: 13,
                              height: 1.2,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (lap.memo.trim().isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              lap.memo.replaceAll('\n', ' '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.secondaryText,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _formatDuration(elapsedSeconds),
                  style: TextStyle(
                    color: colors.primaryText,
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                SizedBox(
                  width: 38,
                  height: 44,
                  child: IconButton(
                    tooltip: 'Splitメモ',
                    padding: EdgeInsets.zero,
                    onPressed: onOpenMemo,
                    icon: Icon(
                      lap.memo.trim().isEmpty
                          ? Icons.note_add_outlined
                          : Icons.sticky_note_2,
                      color: colors.utility,
                      size: 16,
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
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 40,
              child: FilledButton.icon(
                key: const ValueKey<String>('mobile-primary-action'),
                onPressed: onPrimary,
                icon: Icon(
                  primaryLabel == '停止' ? Icons.stop : Icons.play_arrow,
                  size: 16,
                ),
                label: Text(primaryLabel),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.accent,
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 40,
              child: OutlinedButton.icon(
                key: const ValueKey<String>('mobile-split-action'),
                onPressed: splitEnabled ? onSplit : null,
                icon: const Icon(Icons.call_split, size: 16),
                label: const Text('Split'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.primaryText,
                  backgroundColor: colors.buttonBackground,
                  disabledForegroundColor: colors.softText,
                  side: BorderSide(color: colors.buttonBorder),
                  textStyle: const TextStyle(fontSize: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _MobileUtilityButton(
            colors: colors,
            tooltip: 'リセット',
            icon: Icons.refresh,
            size: 40,
            onPressed: onReset,
          ),
          const SizedBox(width: 6),
          _MobileUtilityButton(
            colors: colors,
            tooltip: 'セッションを削除',
            icon: Icons.delete_outline,
            size: 40,
            destructive: true,
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _MobileCircleIconButton extends StatelessWidget {
  const _MobileCircleIconButton({
    required this.colors,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 28,
    this.iconSize = 14,
  });

  final _MobileColors colors;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: colors.headerControl,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, size: iconSize, color: colors.utility),
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
    this.size = 32,
    this.destructive = false,
  });

  final _MobileColors colors;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: colors.buttonBackground,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: onPressed,
          child: Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: colors.buttonBorder),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(
              icon,
              size: 16,
              color: destructive ? const Color(0xFFC94848) : colors.utility,
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileSmallPill extends StatelessWidget {
  const _MobileSmallPill({required this.colors, required this.label});

  final _MobileColors colors;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 26,
      constraints: const BoxConstraints(maxWidth: 142),
      padding: const EdgeInsets.symmetric(horizontal: 9),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.buttonBackground,
        border: Border.all(color: colors.buttonBorder),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: colors.primaryText,
          fontSize: 11,
          fontFeatures: const [FontFeature.tabularFigures()],
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
      height: 26,
      width: 174,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colors.headerControl,
        borderRadius: BorderRadius.circular(7),
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
        borderRadius: BorderRadius.circular(6),
        onTap: () => onChanged(mode),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? colors.selectedChip : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 13, color: colors.utility),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(color: colors.primaryText, fontSize: 11),
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
      height: 30,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: foreground,
          backgroundColor: background,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(7),
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
    this.accent = false,
  });

  final _MobileColors colors;
  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final foreground = accent ? colors.accent : colors.primaryText;
    return Container(
      height: 26,
      constraints: const BoxConstraints(minWidth: 62, maxWidth: 126),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: accent
            ? colors.accent.withValues(alpha: 0.12)
            : colors.buttonBackground,
        border: Border.all(
          color: accent
              ? colors.accent.withValues(alpha: 0.38)
              : colors.buttonBorder,
        ),
        borderRadius: BorderRadius.circular(999),
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
                fontSize: 10,
                fontWeight: accent ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 2),
          Icon(Icons.arrow_drop_down, size: 12, color: foreground),
        ],
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
    return AlertDialog(
      backgroundColor: widget.colors.background,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: widget.colors.border),
      ),
      titlePadding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
      contentPadding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
      actionsPadding: const EdgeInsets.fromLTRB(18, 4, 18, 14),
      title: Text(
        widget.title,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
      content: TextField(
        key: const ValueKey<String>('mobile-name-editor-field'),
        controller: _controller,
        autofocus: true,
        maxLines: 1,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: widget.colors.control,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 9,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: widget.colors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: widget.colors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: widget.colors.border),
          ),
        ),
      ),
      actions: [
        _MobileCompactTextButton(
          colors: widget.colors,
          label: 'キャンセル',
          onPressed: () => Navigator.pop(context),
        ),
        _MobileCompactTextButton(
          colors: widget.colors,
          label: '保存',
          prominent: true,
          onPressed: _save,
        ),
      ],
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
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          _MobileUtilityButton(
            colors: colors,
            icon: Icons.close,
            tooltip: '閉じる',
            size: 32,
            onPressed: onClose,
          ),
          const SizedBox(width: 10),
          Text(
            title,
            style: TextStyle(
              color: colors.primaryText,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
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
        '下部のボタンから、現在のセッションをリセットまたは削除できます。',
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
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
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
                                horizontal: 12,
                                vertical: 11,
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
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          section.summary,
                                          style: TextStyle(
                                            color: colors.secondaryText,
                                            fontSize: 11,
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
                              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
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
                                                fontSize: 12,
                                                height: 1.45,
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
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Split名',
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.secondaryText,
                        ),
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: _labelController,
                        maxLines: 1,
                        textInputAction: TextInputAction.done,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.primaryText,
                        ),
                        decoration: _mobileFieldDecoration(
                          colors,
                          hintText: '作業内容',
                          dense: true,
                        ),
                      ),
                      const SizedBox(height: 9),
                      Row(
                        children: [
                          Text(
                            '経過時間',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.secondaryText,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            widget.elapsedText,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.primaryText,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 9),
                      Text(
                        'メモ',
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.secondaryText,
                        ),
                      ),
                      const SizedBox(height: 4),
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
                            fontSize: 12,
                            height: 1.35,
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
                    size: 32,
                    onPressed: _copy,
                  ),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          PopupMenuButton<String>(
                            tooltip: 'サマリー表示フォーマット',
                            initialValue: _formatId,
                            onSelected: (value) {
                              if (value == '_add') {
                                _createCustomFormat();
                                return;
                              }
                              setState(() {
                                _formatId = value;
                                _regenerate();
                              });
                            },
                            itemBuilder: (context) => [
                              for (final format in _formats)
                                PopupMenuItem<String>(
                                  value: format.id,
                                  height: 36,
                                  child: Text(
                                    format.id == templateSummaryFormatId
                                        ? 'テンプレート'
                                        : format.name,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              const PopupMenuDivider(height: 8),
                              const PopupMenuItem<String>(
                                value: '_add',
                                height: 36,
                                child: Row(
                                  children: [
                                    Icon(Icons.add, size: 14),
                                    SizedBox(width: 6),
                                    Text(
                                      'カスタムを追加',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            child: _MobileMenuPill(
                              colors: colors,
                              label: selectedFormat.name,
                              accent: true,
                            ),
                          ),
                          const SizedBox(width: 6),
                          PopupMenuButton<String>(
                            tooltip: '時間表示形式',
                            initialValue: _timeFormat,
                            onSelected: (value) {
                              setState(() {
                                _timeFormat = value;
                                _regenerate();
                              });
                            },
                            itemBuilder: (context) => [
                              for (final format in const [
                                'hourMinute',
                                'decimalHours',
                                'decimalHoursPrecise',
                              ])
                                PopupMenuItem<String>(
                                  value: format,
                                  height: 36,
                                  child: Text(
                                    _summaryTimeOptionLabel(format),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                            ],
                            child: _MobileMenuPill(
                              colors: colors,
                              label: _formatSummaryDuration(
                                totalSeconds,
                                _timeFormat,
                              ),
                            ),
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
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
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
                            fontSize: 12,
                            height: 1.35,
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

  Future<void> _requestDataAction(_MobileSettingsDataAction action) async {
    final colors = _MobileColors(isMonochrome: _isMonochrome);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colors.background,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: colors.border),
        ),
        title: Text(
          action.title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        content: Text(action.message, style: const TextStyle(fontSize: 12)),
        actions: [
          _MobileCompactTextButton(
            colors: colors,
            label: 'キャンセル',
            onPressed: () => Navigator.pop(context, false),
          ),
          _MobileCompactTextButton(
            colors: colors,
            label: action.confirmLabel,
            prominent: !action.destructive,
            destructive: action.destructive,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
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
                              PopupMenuButton<String>(
                                tooltip: '表示フォーマットを選択',
                                initialValue: _selectedFormatId,
                                onSelected: (value) {
                                  if (value == '_add') {
                                    _addCustomFormat();
                                  } else {
                                    setState(() => _selectedFormatId = value);
                                  }
                                },
                                itemBuilder: (context) => [
                                  for (final format in _formats)
                                    PopupMenuItem<String>(
                                      value: format.id,
                                      height: 36,
                                      child: Text(
                                        format.id == templateSummaryFormatId
                                            ? 'テンプレート'
                                            : format.name,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  const PopupMenuDivider(height: 8),
                                  const PopupMenuItem<String>(
                                    value: '_add',
                                    height: 36,
                                    child: Row(
                                      children: [
                                        Icon(Icons.add, size: 14),
                                        SizedBox(width: 6),
                                        Text(
                                          'カスタムを追加',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                child: _MobileMenuPill(
                                  colors: colors,
                                  label: selectedFormat.name,
                                ),
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
                                size: 28,
                                onPressed: _editSelectedFormat,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        _MobileSettingsRow(
                          colors: colors,
                          title: '時間表示形式',
                          trailing: PopupMenuButton<String>(
                            tooltip: '時間表示形式を選択',
                            initialValue: _timeFormat,
                            onSelected: (value) {
                              setState(() => _timeFormat = value);
                            },
                            itemBuilder: (context) => [
                              for (final format in const [
                                'hourMinute',
                                'decimalHours',
                                'decimalHoursPrecise',
                              ])
                                PopupMenuItem<String>(
                                  value: format,
                                  height: 36,
                                  child: Text(
                                    _summaryTimeOptionLabel(format),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                            ],
                            child: _MobileMenuPill(
                              colors: colors,
                              label: _summaryTimeOptionLabel(_timeFormat),
                            ),
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
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(
            label,
            style: TextStyle(
              color: colors.secondaryText,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
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
                style: TextStyle(color: colors.primaryText, fontSize: 12),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  style: TextStyle(color: colors.secondaryText, fontSize: 9),
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
      height: 28,
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
                      fontSize: 10,
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
      height: 28,
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
            width: 54,
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.primaryText, fontSize: 10),
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
        width: 27,
        height: 27,
        child: Icon(
          icon,
          size: 13,
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
    final color = destructive ? const Color(0xFFC94848) : colors.primaryText;
    return Material(
      color: colors.buttonBackground,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onPressed,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border.all(color: colors.buttonBorder),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(color: color, fontSize: 12),
                ),
              ),
              Icon(Icons.chevron_right, size: 16, color: colors.secondaryText),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: widget.colors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(
          '${widget.initialFormat.name}を削除しますか？',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          'このカスタムフォーマットと置換ルールを削除します。',
          style: TextStyle(fontSize: 12),
        ),
        actions: [
          _MobileCompactTextButton(
            colors: widget.colors,
            label: 'キャンセル',
            onPressed: () => Navigator.pop(context, false),
          ),
          _MobileCompactTextButton(
            colors: widget.colors,
            label: '削除',
            destructive: true,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
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
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 6),
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
        width: 28,
        height: 28,
        child: Icon(icon, size: 15, color: color),
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

class _MobileSessionTitle extends StatelessWidget {
  const _MobileSessionTitle({required this.colors, required this.title});

  final _MobileColors colors;
  final String title;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: colors.primaryText,
      fontSize: 17,
      fontWeight: FontWeight.w600,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final direction = Directionality.of(context);
        final painter = TextPainter(
          text: TextSpan(text: title, style: style),
          maxLines: 1,
          textDirection: direction,
        )..layout(maxWidth: math.max(0, constraints.maxWidth - 21));
        final underlineWidth = math
            .max(42.0, painter.width + 21)
            .clamp(0.0, constraints.maxWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.edit_outlined,
                  size: 13,
                  color: colors.secondaryText,
                ),
              ],
            ),
            const SizedBox(height: 2),
            Container(
              width: underlineWidth,
              height: 1,
              color: colors.primaryText,
            ),
          ],
        );
      },
    );
  }
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

  Color get background => surface;
  Color get surface =>
      isMonochrome ? const Color(0xFFF2F2F2) : const Color(0xFFE8ECEC);
  Color get section => isMonochrome
      ? Colors.black.withValues(alpha: 0.06)
      : Colors.white.withValues(alpha: 0.55);
  Color get lapCard => isMonochrome
      ? Colors.black.withValues(alpha: 0.05)
      : Colors.white.withValues(alpha: 0.52);
  Color get control => isMonochrome
      ? Colors.white.withValues(alpha: 0.76)
      : Colors.white.withValues(alpha: 0.70);
  Color get primaryText => const Color(0xFF101318);
  Color get secondaryText => Colors.black.withValues(alpha: 0.58);
  Color get softText => Colors.black.withValues(alpha: 0.24);
  Color get utility => const Color(0xFF3C3C3C);
  Color get accent =>
      isMonochrome ? const Color(0xFF404040) : const Color(0xFF0A84FF);
  Color get border => isMonochrome
      ? Colors.black.withValues(alpha: 0.24)
      : Colors.black.withValues(alpha: 0.13);
  Color get strongBorder => isMonochrome
      ? Colors.black.withValues(alpha: 0.38)
      : Colors.black.withValues(alpha: 0.28);
  Color get headerControl => isMonochrome
      ? Colors.black.withValues(alpha: 0.14)
      : Colors.black.withValues(alpha: 0.08);
  Color get selectedChip => isMonochrome
      ? Colors.black.withValues(alpha: 0.20)
      : Colors.black.withValues(alpha: 0.14);
  Color get selectedRow => isMonochrome
      ? Colors.black.withValues(alpha: 0.12)
      : Colors.white.withValues(alpha: 0.82);
  Color get buttonBackground => Colors.white.withValues(alpha: 0.42);
  Color get buttonBorder => Colors.black.withValues(alpha: 0.18);
  Color get track => isMonochrome
      ? const Color(0xFFEDEDED)
      : Colors.black.withValues(alpha: 0.08);
  Color get ringBorder => Colors.white;

  Color lapColor(int index) {
    if (isMonochrome) {
      const values = [
        Color(0xFF343434),
        Color(0xFF555555),
        Color(0xFF737373),
        Color(0xFF909090),
        Color(0xFFADADAD),
      ];
      return values[math.max(0, index - 1) % values.length];
    }
    const values = [
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
    borderRadius: BorderRadius.circular(7),
    borderSide: BorderSide(color: colors.border),
  );
  return InputDecoration(
    isDense: dense,
    filled: true,
    fillColor: colors.control,
    hintText: hintText,
    hintStyle: TextStyle(color: colors.secondaryText, fontSize: 12),
    contentPadding: dense
        ? const EdgeInsets.symmetric(horizontal: 9, vertical: 8)
        : const EdgeInsets.all(9),
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
