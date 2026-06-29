import 'dart:math' as math;

import 'package:flutter/material.dart';

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
}

enum _SplitMode { radio, checkbox }

class DesktopSessionView extends StatefulWidget {
  const DesktopSessionView({super.key});

  @override
  State<DesktopSessionView> createState() => _DesktopSessionViewState();
}

class _DesktopSessionViewState extends State<DesktopSessionView> {
  _PreviewOverlay _overlay = _PreviewOverlay.none;
  _SplitMode _splitMode = _SplitMode.checkbox;
  bool _isLocked = false;
  bool _isMonochrome = false;

  final List<_PreviewSession> _sessions = const [
    _PreviewSession('2026/6/28'),
    _PreviewSession('2026/6/26'),
    _PreviewSession('2026/6/24'),
  ];

  final List<_PreviewLap> _laps = const [
    _PreviewLap(
      index: 1,
      label: 'websocket, push動\n作確認',
      elapsed: '02:46:18',
      seconds: 9978,
      hasMemo: true,
      active: false,
      selected: false,
    ),
    _PreviewLap(
      index: 2,
      label: 'MTG',
      elapsed: '00:32:50',
      seconds: 1970,
      hasMemo: true,
      active: false,
      selected: false,
    ),
    _PreviewLap(
      index: 3,
      label: '池側くんとのDB更新',
      elapsed: '00:13:23',
      seconds: 803,
      hasMemo: true,
      active: false,
      selected: false,
    ),
    _PreviewLap(
      index: 4,
      label: 'Issue作成',
      elapsed: '00:51:51',
      seconds: 3111,
      hasMemo: true,
      active: true,
      selected: false,
    ),
    _PreviewLap(
      index: 5,
      label: 'PR確認',
      elapsed: '00:35:12',
      seconds: 2112,
      hasMemo: true,
      active: true,
      selected: false,
    ),
  ];

  int get _totalSeconds => _laps.fold(0, (sum, lap) => sum + lap.seconds);

  void _show(_PreviewOverlay overlay) {
    setState(() {
      _overlay = overlay;
    });
  }

  void _hideOverlay() {
    setState(() {
      _overlay = _PreviewOverlay.none;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = _DesktopPreviewColors(isMonochrome: _isMonochrome);

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
                    sessions: _sessions,
                    isLocked: _isLocked,
                    onHelp: () => _show(_PreviewOverlay.help),
                    onToggleLock: () {
                      setState(() {
                        _isLocked = !_isLocked;
                      });
                    },
                    onSessionList: () => _show(_PreviewOverlay.sessionList),
                    onAddSession: () {},
                    onSettings: () => _show(_PreviewOverlay.settings),
                  ),
                  const SizedBox(height: 4),
                  Divider(height: 1, color: colors.border),
                  const SizedBox(height: 8),
                  _SessionStatusRow(
                    colors: colors,
                    splitMode: _splitMode,
                    totalElapsed: _formatDuration(_totalSeconds),
                    onToggleSplitMode: (mode) {
                      setState(() {
                        _splitMode = mode;
                      });
                    },
                    onSummary: () => _show(_PreviewOverlay.summary),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _TimelineCard(
                          colors: colors,
                          laps: _laps,
                          totalSeconds: _totalSeconds,
                          onCycleTap: () => _show(_PreviewOverlay.settings),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _LapList(
                            colors: colors,
                            laps: _laps,
                            splitMode: _splitMode,
                            onMemo: () => _show(_PreviewOverlay.memo),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _BottomActionRow(
                    colors: colors,
                    onReset: () => _show(_PreviewOverlay.resetConfirmation),
                    onDelete: () => _show(_PreviewOverlay.deleteConfirmation),
                  ),
                ],
              ),
            ),
            _OverlayLayer(
              overlay: _overlay,
              colors: colors,
              isMonochrome: _isMonochrome,
              onClose: _hideOverlay,
              onOpenGuide: () => _show(_PreviewOverlay.guide),
              onOpenContact: () {},
              onToggleTheme: () {
                setState(() {
                  _isMonochrome = !_isMonochrome;
                });
              },
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
    required this.isLocked,
    required this.onHelp,
    required this.onToggleLock,
    required this.onSessionList,
    required this.onAddSession,
    required this.onSettings,
  });

  final _DesktopPreviewColors colors;
  final List<_PreviewSession> sessions;
  final bool isLocked;
  final VoidCallback onHelp;
  final VoidCallback onToggleLock;
  final VoidCallback onSessionList;
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
    required this.onOverflow,
  });

  final _DesktopPreviewColors colors;
  final List<_PreviewSession> sessions;
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
                return Container(
                  width: 72,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: index == 0
                        ? colors.selectedChip
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    session.title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
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
    required this.splitMode,
    required this.totalElapsed,
    required this.onToggleSplitMode,
    required this.onSummary,
  });

  final _DesktopPreviewColors colors;
  final _SplitMode splitMode;
  final String totalElapsed;
  final ValueChanged<_SplitMode> onToggleSplitMode;
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
            child: _SessionTitleUnderline(title: '2026/6/28', colors: colors),
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
  final _SplitMode splitMode;
  final ValueChanged<_SplitMode> onChanged;

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
          _modeButton(Icons.radio_button_checked, _SplitMode.radio),
          _modeButton(Icons.check_box, _SplitMode.checkbox),
        ],
      ),
    );
  }

  Widget _modeButton(IconData icon, _SplitMode mode) {
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
  const _SessionTitleUnderline({required this.title, required this.colors});

  final String title;
  final _DesktopPreviewColors colors;

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
              Text(
                title,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
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
    required this.totalSeconds,
    required this.onCycleTap,
  });

  final _DesktopPreviewColors colors;
  final List<_PreviewLap> laps;
  final int totalSeconds;
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
                  totalSeconds: totalSeconds,
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
                      '4h',
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
    required this.splitMode,
    required this.onMemo,
  });

  final _DesktopPreviewColors colors;
  final List<_PreviewLap> laps;
  final _SplitMode splitMode;
  final VoidCallback onMemo;

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
                splitMode: splitMode,
                onMemo: onMemo,
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Stopped',
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
    required this.splitMode,
    required this.onMemo,
  });

  final _DesktopPreviewColors colors;
  final _PreviewLap lap;
  final _SplitMode splitMode;
  final VoidCallback onMemo;

  @override
  Widget build(BuildContext context) {
    final icon = splitMode == _SplitMode.radio
        ? (lap.selected
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked)
        : (lap.active ? Icons.check_box : Icons.check_box_outline_blank);

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
              Icon(icon, size: 16, color: colors.primaryText),
              const SizedBox(width: 7),
              Expanded(
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
                  lap.hasMemo ? Icons.sticky_note_2 : Icons.note_alt_outlined,
                ),
              ),
              const SizedBox(width: 3),
              Text(
                lap.elapsed,
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
    required this.onReset,
    required this.onDelete,
  });

  final _DesktopPreviewColors colors;
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
            label: '再開',
            prominent: true,
            onPressed: () {},
          ),
          const SizedBox(width: 10),
          _TextActionButton(
            colors: colors,
            label: 'Split',
            enabled: false,
            onPressed: () {},
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
    required this.isMonochrome,
    required this.onClose,
    required this.onOpenGuide,
    required this.onOpenContact,
    required this.onToggleTheme,
  });

  final _PreviewOverlay overlay;
  final _DesktopPreviewColors colors;
  final bool isMonochrome;
  final VoidCallback onClose;
  final VoidCallback onOpenGuide;
  final VoidCallback onOpenContact;
  final VoidCallback onToggleTheme;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (overlay == _PreviewOverlay.sessionList)
          Positioned(
            right: 26,
            top: 46,
            child: _SessionOverflowPanel(colors: colors),
          ),
        if (overlay == _PreviewOverlay.resetConfirmation)
          _ConfirmationOverlay(
            colors: colors,
            title: 'リセットしますか？',
            message: '現在表示中のセッションとSplitを初期状態に戻します。',
            confirmTitle: 'リセット',
            onClose: onClose,
          ),
        if (overlay == _PreviewOverlay.deleteConfirmation)
          _ConfirmationOverlay(
            colors: colors,
            title: 'セッションを削除しますか？',
            message: '現在表示中のセッションを削除します。',
            confirmTitle: '削除',
            destructive: !isMonochrome,
            onClose: onClose,
          ),
        if (overlay == _PreviewOverlay.memo)
          _CenteredOverlay(
            onClose: onClose,
            child: _MemoOverlay(colors: colors, onClose: onClose),
          ),
        if (overlay == _PreviewOverlay.summary)
          _CenteredOverlay(
            onClose: onClose,
            child: _SummaryOverlay(colors: colors, onClose: onClose),
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
              onToggleTheme: onToggleTheme,
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
  const _SessionOverflowPanel({required this.colors});

  final _DesktopPreviewColors colors;

  @override
  Widget build(BuildContext context) {
    const sessions = ['2026/6/28', '2026/6/26', '2026/6/24'];

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
            final selected = index == 0;
            return _SessionMenuRow(
              colors: colors,
              title: sessions[index],
              selected: selected,
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
  });

  final _DesktopPreviewColors colors;
  final String title;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () {},
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
    this.destructive = false,
  });

  final _DesktopPreviewColors colors;
  final String title;
  final String message;
  final String confirmTitle;
  final VoidCallback onClose;
  final bool destructive;

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
                OutlinedButton(onPressed: onClose, child: const Text('キャンセル')),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: onClose,
                  style: destructive
                      ? FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFC94848),
                        )
                      : null,
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
  const _MemoOverlay({required this.colors, required this.onClose});

  final _DesktopPreviewColors colors;
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
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Text(
            'Split名',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
          const SizedBox(height: 6),
          const TextField(
            controller: null,
            decoration: InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              hintText: 'websocket, push動作確認',
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
              const Text('02:46:18'),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'メモ',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
          const SizedBox(height: 6),
          const SizedBox(
            height: 118,
            child: TextField(
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'websocket と push 動作を確認',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton(onPressed: onClose, child: const Text('閉じる')),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryOverlay extends StatelessWidget {
  const _SummaryOverlay({required this.colors, required this.onClose});

  final _DesktopPreviewColors colors;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    const summary = '''
websocket, push動作確認　(2.8h)
MTG　(0.5h)
池側くんとのDB更新　(0.2h)
Issue作成　(0.9h)
PR確認　(0.6h)''';

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
              _SmallPill(colors: colors, label: '- メモ'),
              const SizedBox(width: 6),
              _SmallPill(colors: colors, label: '1.1h'),
              const Spacer(),
              Text(
                '2026/6/28 (5.0h)',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: colors.secondaryText),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'コピー',
                iconSize: 16,
                onPressed: () {},
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
            child: const Text(summary, style: TextStyle(height: 1.45)),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton(onPressed: onClose, child: const Text('閉じる')),
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
    required this.onToggleTheme,
  });

  final _DesktopPreviewColors colors;
  final bool isMonochrome;
  final VoidCallback onClose;
  final VoidCallback onOpenGuide;
  final VoidCallback onOpenContact;
  final VoidCallback onToggleTheme;

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
                      onTap: (_) => onToggleTheme(),
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
                      trailing: const _InlineStepperValue(value: '4時間'),
                    ),
                    const SizedBox(height: 8),
                    _SectionLabel(
                      colors: colors,
                      label: '新規セッションのデフォルトSplit配分モード',
                    ),
                    const SizedBox(height: 6),
                    _ChoiceBar(
                      colors: colors,
                      selectedIndex: 0,
                      labels: const ['ラジオ', 'チェック'],
                      onTap: (_) {},
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
                      trailing: _MenuValuePill(colors: colors, label: '- メモ'),
                    ),
                    const SizedBox(height: 6),
                    _SettingsRow(
                      colors: colors,
                      title: '時間表示形式',
                      trailing: _MenuValuePill(colors: colors, label: '1.1h'),
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
                      title: 'セッション情報',
                      icon: Icons.delete_outline,
                      destructive: true,
                    ),
                    const SizedBox(height: 6),
                    _ActionRow(
                      colors: colors,
                      title: 'Split情報',
                      icon: Icons.delete_outline,
                      destructive: true,
                    ),
                    const SizedBox(height: 6),
                    _ActionRow(
                      colors: colors,
                      title: '設定のみ初期化',
                      icon: Icons.refresh,
                    ),
                    const SizedBox(height: 6),
                    _ActionRow(
                      colors: colors,
                      title: '全データ初期化',
                      icon: Icons.warning_amber,
                      destructive: true,
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
              FilledButton(onPressed: onClose, child: const Text('閉じる')),
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

class _GuideOverlay extends StatelessWidget {
  const _GuideOverlay({required this.colors, required this.onClose});

  final _DesktopPreviewColors colors;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    const sections = [
      ('計測を進める', '開始・Split・停止・再開の流れ'),
      ('セッションを切り替える', '日ごとや作業単位で計測先を分ける'),
      ('Split を選ぶ', 'ラジオ配分とチェック配分を切り替える'),
      ('メモとサマリーを使う', 'Split ごとのメモと全体サマリーを確認'),
      ('ショートカットを使う', 'Popover を開かずに主要操作を実行'),
      ('表示や初期値を整える', 'テーマ、リング周期、初期モード、ロックなどの調整'),
    ];

    return _ModalSurface(
      colors: colors,
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
                        color: colors.secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onClose,
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
              itemCount: sections.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final section = sections[index];
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(
                      alpha: index == 0 ? 0.78 : 0.62,
                    ),
                    border: Border.all(color: colors.border),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              section.$1,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              section.$2,
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.secondaryText,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        index == 0
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                      ),
                    ],
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
  const _SmallPill({required this.colors, required this.label});

  final _DesktopPreviewColors colors;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
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
  const _InlineStepperValue({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.remove_circle_outline, size: 17),
        const SizedBox(width: 8),
        Text(value, style: const TextStyle(fontSize: 13)),
        const SizedBox(width: 8),
        const Icon(Icons.add_circle_outline, size: 17),
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
          Icon(
            Icons.keyboard_arrow_down,
            size: 14,
            color: colors.secondaryText,
          ),
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
    required this.totalSeconds,
  });

  final _DesktopPreviewColors colors;
  final List<_PreviewLap> laps;
  final int totalSeconds;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const cycleSeconds = 4 * 60 * 60;
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
      ranges.add(_LapRange(lap: lap, start: cursor, end: cursor + lap.seconds));
      cursor += lap.seconds;
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

  Color get disabledText => const Color(0xFFBFD9FF);

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

  @override
  bool operator ==(Object other) {
    return other is _DesktopPreviewColors && other.isMonochrome == isMonochrome;
  }

  @override
  int get hashCode => isMonochrome.hashCode;
}

class _PreviewSession {
  const _PreviewSession(this.title);

  final String title;
}

class _PreviewLap {
  const _PreviewLap({
    required this.index,
    required this.label,
    required this.elapsed,
    required this.seconds,
    required this.hasMemo,
    required this.active,
    required this.selected,
  });

  final int index;
  final String label;
  final String elapsed;
  final int seconds;
  final bool hasMemo;
  final bool active;
  final bool selected;
}

class _LapRange {
  const _LapRange({required this.lap, required this.start, required this.end});

  final _PreviewLap lap;
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
