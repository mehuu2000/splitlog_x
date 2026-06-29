# Step 1-1 Inventory: Existing SplitLog

This document inventories the current Swift/AppKit SplitLog implementation so the Flutter rebuild can reproduce the desktop experience first.

The files under `SplitLog/sample/*.png` are not treated as visual truth. They were reference images for the old build, not the completed UI.

## Source Of Truth

- Visual structure: SwiftUI/AppKit source in `/Users/hamada/projects/SplitLog`
- Behavior: Swift source plus `README.md`
- Screenshots: use generated screenshots from the running old app only if available later

## App Shell

Existing desktop shell:

- macOS menu bar resident app
- No normal app window
- `LSUIElement = YES`
- Menu bar button uses `timer` SF Symbol
- Main surface is an `NSPopover`
- Popover content size is `540 x 380`
- Popover appears from the menu bar item
- Popover can be locked so outside clicks do not close it
- App exits only through explicit `SplitLogを終了`

Important source files:

- `SplitLog/App/SplitLogApp.swift`
- `SplitLog/App/AppDelegate.swift`
- `SplitLog/Presentation/MenuBar/MenuBarController.swift`
- `SplitLog/Presentation/Views/SessionPopover/SessionPopoverView.swift`

Flutter desktop implication:

- macOS should use menu bar/tray behavior.
- Windows should use task tray behavior.
- Desktop surface should be a compact popover-like window approximating `540 x 380`.
- Close/outside-click behavior should map to hide, not quit.

## Main Desktop Layout

Root view:

- Outer padding: 14
- Fixed desktop surface: `540 x 380`
- Material-style translucent background
- Vertical layout with these regions:
  1. Header
  2. Divider
  3. Session/status row
  4. Main content row
  5. Bottom action row
  6. Overlay stack for modals/toasts/session list

### Header

Left side:

- App label: `SplitLog`
- Timer icon
- Help button: `?`
- Popover lock button:
  - unlocked: `lock.open`
  - locked: `lock.fill`

Right side:

- Horizontal session selector capsule
- Add session button: `plus`
- Settings button: `gearshape`

### Session/status row

Left:

- Session title area, width about 250, height about 28
- Title is horizontally scrollable
- Title underline width is calculated from text
- Tapping title edits selected session title inline

Right:

- Split accumulation mode segmented icon control
  - radio: selected `largecircle.fill.circle`, unselected `circle`
  - checkbox: selected `checkmark.square.fill`, unselected `square`
- Summary button: `doc.text`
- Total elapsed badge:
  - label: `全体経過`
  - time format: `HH:MM:SS`

### Main content row

Left:

- Timeline ring inside a rounded section
- Frame about `198 x 198`, with 8 padding
- Ring cycle badge in top-left:
  - icon `arrow.clockwise`
  - text like `3h`
  - clicking opens settings

Right:

- Split/Lap list
- Empty state:
  - `Splitはまだありません`
  - `開始して下さい`
- Non-empty state:
  - vertically scrollable rows
  - auto-scroll to new lap
  - auto-scroll to selected lap when shortcut selection changes

### Bottom action row

Left:

- Primary button:
  - idle/finished: `開始`
  - running/paused: `停止`
  - stopped: `再開`
- Secondary button:
  - `Split`
  - disabled unless state is running

Right:

- Reset button: `arrow.counterclockwise`
- Delete current session button: `trash`
- Both disabled when no session exists

## Split/Lap Row

Each row:

- Rounded rectangle card
- Height driven by content and vertical padding
- Leading control:
  - radio mode: selected/unselected radio icon
  - checkbox mode: checked/unchecked square icon
- Label:
  - text format: `{label}：`
  - tapping label enters inline edit
  - empty committed label resets to default `作業{index}`
- Memo button: `note.text`
- Elapsed time: `HH:MM:SS`, monospaced digits
- Bottom color strip, height 2

Selection behavior:

- Radio mode: leading control selects target lap and only selected lap receives time
- Checkbox mode: leading control toggles active state and selects the lap
- Checkbox mode must keep at least one active lap

## Timeline Ring

The ring visualizes lap durations in chronological cumulative order.

Core rules:

- Ring cycle length is configurable in hours, default `3`
- If total elapsed is less than one cycle:
  - show inner ring only
- If total elapsed reaches or exceeds one cycle:
  - inner ring shows previous cycle window
  - outer ring shows current cycle window
- Each lap contributes a colored slice by cumulative duration
- Slice colors use the lap index
- Color mode uses a 24-color RGB wheel
- Monochrome mode uses a 24-step grayscale wheel

Visual details:

- Inner line width: 30
- Outer line width: 30
- Segment boundary line width: 1
- Perimeter border line width: 2
- Track color depends on theme

## Overlays And Modals

All overlays are shown inside the compact desktop surface, layered with `ZStack`.

### Session overflow panel

- Opens from session selector overflow button
- Size about `180 x 260`
- Uses regular material background
- Shows all sessions as rows
- Selected session row is highlighted
- Clicking outside closes panel

### Reset/Delete confirmation

Used for:

- Current session reset
- Current session delete
- Settings storage actions

Shape:

- Width about 320
- Title
- Message
- `キャンセル`
- Confirm button

Main confirmation text:

- Delete session:
  - title: `セッションを削除しますか？`
  - message: `現在表示中のセッションを削除します。`
  - confirm: `削除`
- Reset session:
  - title: `リセットしますか？`
  - message: `現在表示中のセッションとSplitを初期状態に戻します。`
  - confirm: `リセット`

### Split memo

Title: `Splitメモ`

Fields:

- `Split名`
- `経過時間`
- `メモ`
- `閉じる`

Behavior:

- Opens from row memo icon or shortcut
- Edits both lap label and memo
- Commits changes on close

### Summary

Title: `サマリー`

Header controls:

- Memo format toggle:
  - `- メモ`
  - `メモ`
- Time format toggle:
  - decimal hours preview, e.g. `1.5h`
  - hour/minute preview, e.g. `1時間30分`
- Header text: `{sessionTitle} ({duration})`
- Copy button: `doc.on.doc`

Body:

- Text editor with generated summary
- Close button

Summary generation:

- If no laps: `Splitはまだありません`
- For each lap:
  - `{lap.label}　({duration})`
  - if memo exists:
    - plain mode: raw memo
    - bulleted mode: non-empty lines as `   - {paragraph}`

Copy behavior:

- Copies summary to clipboard
- Success toast: `サマリーをコピーしました`
- Error toast: `サマリーのコピーに失敗しました。`

### Settings

Title: `設定`

Desktop modal size about `360 x 360`.

Sections:

- `テーマカラー`
  - segmented picker: `カラー`, `モノクロ`
- `表示`
  - ring cycle stepper: `リング周期（1周）`, `1...24`, default `3時間`
  - default split accumulation mode picker: `ラジオ`, `チェック`
  - helper: `新しく追加するセッションの初期値として使います。`
- `サマリー表示`
  - memo format: `- メモ`, `メモ`
  - time format: decimal hours or hour/minute
- `案内`
  - `操作説明`
  - `お問い合わせ`
- `ストレージ管理`
  - `セッション情報`
  - `Split情報`
  - `設定のみ初期化`
  - `全データ初期化`
- `アプリ`
  - `SplitLogを終了`

Storage action confirmations:

- Session data:
  - title: `セッション情報を削除しますか？`
  - message: `全セッション・Split・メモを削除します。`
- Split data:
  - title: `Split情報を削除しますか？`
  - message: `全セッションのSplit・メモを削除します（セッション名は保持）。`
- Reset settings:
  - title: `設定のみ初期化しますか？`
  - message: `アプリ設定のみをデフォルトに戻します。`
- Initialize all:
  - title: `全データを初期化しますか？`
  - message: `全データと設定を削除して初期状態に戻します。`

### Help hub

Title: `案内`

Cards:

- `操作説明`
  - subtitle: `このアプリでできることと使い方を確認`
- `お問い合わせ`
  - subtitle: `不具合報告や相談用の導線`

### Operation guide

Title: `操作説明`

Subtitle:

- `SplitLog でできることを順番に確認できます。`

Expandable sections:

- `計測を進める`
- `セッションを切り替える`
- `Split を選ぶ`
- `メモとサマリーを使う`
- `ショートカットを使う`
- `表示や初期値を整える`

## Domain Model

### Session state

Values:

- `idle`
- `running`
- `paused`
- `stopped`
- `finished`

Note: UI currently mainly transitions through `idle`, `running`, `stopped`, with paused support in service logic.

### WorkSession

Fields:

- `id`
- `title`
- `startedAt`
- `endedAt`

### WorkLap

Fields:

- `id`
- `sessionId`
- `index`
- `startedAt`
- `endedAt`
- `accumulatedDuration`
- `label`
- `memo`

### Settings

Fields:

- `themeMode`: `color` or `monochrome`
- `timelineRingHoursPerCycle`: default 3, clamped at least 1, UI range 1...24
- `summaryTimeFormat`: `decimalHours` or `hourMinute`
- `summaryMemoFormat`: `bulleted` or `plain`
- `defaultSplitAccumulationMode`: `radio` or `checkbox`

Flutter v1 addition:

- Desktop shortcut enabled: boolean, default enabled unless implementation proves unstable

## Core Behavior

### Session creation

- Starting with no selected session creates a running session
- Adding a session creates an idle session and selects it
- New session is inserted at the beginning of session order
- Starting/selecting a session stops other running sessions

Default session title:

- Base title: `yyyy/M/d`
- If same date title already exists, suffix with `-A`, `-B`, ...

### Starting/stopping/resuming

Primary action:

- `idle` or `finished`: start
- `running` or `paused`: stop
- `stopped`: resume

Stop:

- Transitions running/paused session to `stopped`
- Running session distributes pending elapsed seconds first

Resume:

- Transitions stopped/paused to running
- Updates paused duration accounting

### Split creation

Only works while running.

Behavior:

- Distributes pending whole seconds first
- Closes current lap by setting `endedAt`
- Appends new lap with next index
- New lap label: `作業{index}`
- Selects new lap

Mode-specific behavior:

- Radio: new lap becomes the only active target
- Checkbox: existing checked laps stay checked, new lap is also checked

### Lap time distribution

Elapsed time is distributed by whole seconds.

Radio mode:

- Only selected lap receives elapsed seconds

Checkbox mode:

- Checked laps receive elapsed seconds by round-robin distribution
- Distribution order follows lap order
- At least one active lap is kept by normalization

### Reset/delete/data actions

- Reset selected session:
  - selected session returns to idle
  - session title remains
  - all laps/memos removed
- Delete selected session:
  - removes selected session
  - selects previous session if possible
  - if no sessions remain, returns to idle and clears persisted state
- Delete all session data:
  - removes all sessions, splits, memos
- Delete all split data:
  - keeps sessions
  - clears all splits/memos and resets sessions to idle
- Reset settings:
  - restores default settings
- Initialize all data:
  - clears all session data and settings

## Persistence

Current Swift version:

- Session data is JSON file via `FileSessionStore`
- Default file name: `sessions.json`
- Stored under app support `SplitLog` directory
- Settings are stored in `UserDefaults` under key `app_settings`

Snapshot schema:

- `schemaVersion`, currently 4
- `savedAt`
- `contexts`
- `sessionOrder`
- `selectedSessionID`
- `nextSessionNumber`

Persisted context:

- `session`
- `laps`
- `selectedLapID`
- `activeLapIDs`
- `splitAccumulationMode`
- `state`
- `pauseStartedAt`
- `lastDistributedWholeSeconds`
- `distributionCursor`
- `totalPausedDuration`

Restore behavior:

- Laps are sorted by index
- Invalid selected/active lap IDs are normalized
- If a persisted session was running, launch restore treats it as stopped at restore time
- This old behavior should be preserved for old-data import unless Flutter mobile restore rules require a separate migration strategy

## Desktop Shortcuts

Current shortcuts:

- `⌘⌃S`: Split
- `⌘⌃X`: Stop
- `⌘⌃R`: Resume
- `⌘⌃V`: Toggle popover
- `⌘⌃M`: Open current lap memo
- `⌘⌃1...9`: Select/toggle lap by display index
- `⌘⌃0`: Select/toggle latest lap
- `⌘⌃↑`: Move selected lap up
- `⌘⌃↓`: Move selected lap down

Flutter v1:

- Desktop only
- Global on/off setting required
- Key remapping not required for v1

## Contact Support

Old app opens `mailto:hamachii.project@proton.me`.

Subject:

- `RunCat お問い合わせ`

Body includes:

- SplitLog version
- macOS version
- request category placeholder
- summary placeholder

Note: subject says `RunCat お問い合わせ` in current source. Flutter implementation should preserve only if exact compatibility is desired; otherwise confirm whether to correct to `SplitLog お問い合わせ`.

## Step 1 Reproduction Checklist

Desktop static UI:

- [ ] 540 x 380 compact surface
- [ ] Header with app label, help, lock, session selector, add, settings
- [ ] Session/status row with editable session title, split mode control, summary, total elapsed
- [ ] Timeline ring card with cycle badge
- [ ] Split list rows and empty state
- [ ] Bottom primary/Split/reset/delete actions
- [ ] Session overflow panel
- [ ] Confirmation overlay
- [ ] Memo overlay
- [ ] Summary overlay
- [ ] Settings overlay
- [ ] Help hub and operation guide
- [ ] Toast messages

Core logic:

- [ ] Session model and snapshot schema
- [ ] Settings model
- [ ] Start/stop/resume
- [ ] Add/select/delete/reset sessions
- [ ] Split/lap creation
- [ ] Radio/checkbox distribution
- [ ] Label/memo editing
- [ ] Summary generation
- [ ] Timeline slice calculation
- [ ] JSON persistence
- [ ] Old `sessions.json` import

macOS shell:

- [ ] Menu bar icon
- [ ] Compact window/popover show/hide
- [ ] Close means hide
- [ ] Explicit quit
- [ ] Popover lock equivalent
- [ ] Desktop shortcut on/off setting

