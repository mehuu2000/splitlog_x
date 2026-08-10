# SplitLog Development Guide

## この文書について

この文書は、SplitLogの開発環境を準備し、実装・検証を行う開発者向けのガイドです。

現在完成しているのはmacOS版v1とWindows版v1です。両Desktop版は共通のFlutter UIとコアロジックを使い、常駐・ウィンドウ・ショートカットなどをOS別のネイティブ層で実装しています。iPhone、Androidは共通Mobile UI、基本操作、ローカル保存、ライフサイクル復帰まで実装済みで、Simulator/Emulator検証も完了しています。実機検証と配布準備が残っています。

## 必要な環境

共通:

- Git
- Flutter stable
- `pubspec.yaml`のDart SDK制約を満たすFlutter SDK
- VS Code、Android Studioなど任意のエディタ

macOS・iPhone:

- macOS
- Xcode
- Xcode Command Line Tools
- `flutter doctor -v`で必要と判定された追加コンポーネント

Android:

- Android Studio
- Android SDK
- Android SDK Command-line Tools
- Android SDKライセンスへの同意

Windows:

- Windows
- Visual Studio（Visual Studio Codeではない）
- `Desktop development with C++`ワークロード

環境を確認します。

```bash
flutter doctor -v
```

`flutter doctor`でエラーが表示された場合は、対象プラットフォームの開発を始める前に解消してください。

## セットアップ

```bash
git clone https://github.com/mehuu2000/splitlog_x.git
cd splitlog_x
flutter pub get
```

利用可能な実行先を確認します。

```bash
flutter devices
```

## 開発版の実行

macOS:

```bash
flutter run -d macos
```

Windows（PowerShell）:

```powershell
flutter run -d windows
```

iPhone:

```bash
flutter run -d "iPhone 17 Pro" -t lib/main_mobile.dart
```

Android:

```bash
flutter run -d <Android端末ID> -t lib/main_mobile.dart
```

`lib/main.dart`はmacOS/Windows、`lib/main_mobile.dart`はiPhone/Androidのエントリーポイントです。Flutter 3.44.xのDesktop Release AOTへ不要なMobile画面ツリーを含めず、各対象で安定してビルドするために分離しています。

実行中のターミナルでは、次のキーを使用できます。

| キー | 操作 |
| --- | --- |
| `r` | ホットリロード |
| `R` | ホットリスタート |
| `q` | アプリを終了 |

ネイティブのSwift/C++コード、アプリアイコン、entitlements、Windowsリソースなどを変更した場合は、ホットリロードでは反映されません。実行中のアプリを終了してから再ビルドしてください。

## プロジェクト構成

```text
lib/
  main.dart
  main_mobile.dart
  core/
    models/
      session_models.dart
      summary_format.dart
    services/
      session_storage_service.dart
      stopwatch_controller.dart
  features/
    session/
      desktop/
        desktop_session_view.dart
      mobile/
        mobile_session_view.dart

macos/Runner/
  AppDelegate.swift
  MainFlutterWindow.swift

windows/runner/
  flutter_window.cpp
  flutter_window.h
  main.cpp
  resources/

test/
  core/
  widget_test.dart
```

主な責務:

| 場所 | 責務 |
| --- | --- |
| `lib/core/models` | セッション、Split、保存スナップショット、サマリーフォーマット |
| `lib/core/services/stopwatch_controller.dart` | タイマー状態、時間配分、Split操作 |
| `lib/core/services/session_storage_service.dart` | JSON保存、復元、旧データ移行 |
| `lib/features/session/desktop` | デスクトップ版UIと画面上の操作 |
| `lib/features/session/mobile` | iPhone・Android共通の全画面UIとライフサイクル処理 |
| `macos/Runner` | メニューバー、ウィンドウ、ショートカットなどのmacOS処理 |
| `windows/runner` | タスクトレイ、ウィンドウ、ショートカットなどのWindows処理 |
| `assets/fonts` | Windows版で使用するInter、Noto Sans JPとライセンス |
| `test` | コアロジック、保存、主要UI操作の回帰テスト |

UIと共有可能なロジックはDartで実装し、OSに依存する常駐・ウィンドウ・ファイル選択などは各プラットフォームのネイティブ層へ閉じ込めます。

## タイマーと状態管理

`StopwatchController`が、1セッション分の次の状態を管理します。

- セッションの開始、停止、再開、リセット
- Splitの作成、選択、終了
- ラジオ方式・チェック方式の時間配分
- 休止時間を除いたセッション経過時間
- 保存スナップショットからの復元
- 重複IDや不正な時間値に対するガード

計測中の表示は毎秒の値を保存する方式ではありません。開始時刻、休止時間、現在状態から経過時間を再計算するため、アプリ画面を閉じても時間を復元できます。

## ローカル保存

`SessionStorageService`がセッションと設定を`sessions.json`へ保存します。

macOSの現在の保存先:

```text
~/Library/Containers/com.example.splitlogx/Data/Library/Application Support/SplitLog_x/sessions.json
```

Windowsの現在の保存先:

```text
%LOCALAPPDATA%\SplitLog\sessions.json
```

iPhoneとAndroidは`path_provider`が返すアプリ専用Application Support領域の`SplitLog/sessions.json`へ保存します。iOSではアプリのサンドボックス内、Androidでは内部files領域となり、ユーザーにファイル操作を要求しません。

`LOCALAPPDATA`を取得できない場合のみ、`%APPDATA%\SplitLog\sessions.json`へフォールバックします。データはアプリの配布フォルダとは別に保存されるため、ZIPを展開し直しても通常は保持されます。

保存時は次の順番で処理します。

1. 保存要求をキューへ追加する
2. JSON全体を`sessions.json.tmp`へ書き込む
3. 書き込み完了後に`sessions.json`へ置き換える
4. 終了時は保存キューの完了を待つ

この構成により、短時間の複数保存による順序逆転と、書き込み途中の終了によるJSON破損を抑えます。読み込み不能な既存JSONを検出した場合は、元ファイルを保護するため自動保存を停止します。

端末間同期、アカウント、ネットワーク上のDBは使用しません。

`path_provider`のプラットフォーム実装は、Flutter 3.44.xのmacOS AOTおよびWindows生成物への影響を避けるため、`pubspec.yaml`の`dependency_overrides`で従来のFlutterプラグイン方式へ固定しています。Flutter SDKまたは依存パッケージを更新するときは、4OSのビルド確認後に固定を外してください。

## 旧SplitLogデータの移行

旧Swift/AppKit版の`sessions.json`を、現在の保存スナップショットへ変換できます。

- macOSでは旧版の既知の保存先を起動時に検知する
- 検知しても自動取り込みはせず、ユーザー確認を挟む
- 設定画面から旧データの検知を再実行できる
- ファイル選択ダイアログから`sessions.json`を手動指定できる
- Windowsでは自動検知を行わず、ファイル選択ダイアログによる手動指定に対応する

移行処理を変更するときは、現行JSONの読み込みと旧JSONの変換を混同しないようにしてください。

## Desktopネイティブ連携

DartとmacOSのSwift、WindowsのC++は`splitlog_x/app`という`MethodChannel`で連携します。

Dartからネイティブ層:

| メソッド | 用途 |
| --- | --- |
| `quitApp` | 保存完了後にアプリを終了 |
| `setShortcutsEnabled` | グローバルショートカットの有効・無効 |
| `setPopoverLocked` | ウィンドウの前面固定 |
| `chooseLegacyFile` | 旧`sessions.json`の選択と読み込み |
| `openContact` | メールアプリを開く |

ネイティブ層からDart:

| メソッド | 用途 |
| --- | --- |
| `shortcutAction` | グローバルショートカットの操作をDartへ通知 |
| `prepareToQuit` | 編集確定と保存完了を待ってから終了可否を返す |

macOSではメニューバー常駐とPopover風ウィンドウをSwiftで管理します。Windowsではタスクトレイ常駐、枠なしウィンドウ、トレイアイコン付近への配置、単一起動をC++で管理します。Windowsだけは日本語の表示品質を揃えるため、InterとNoto Sans JPをアプリへ同梱しています。

設定画面、常駐アイコンのメニュー、macOSの`⌘Q`からの終了要求は、`prepareToQuit`またはDart側の終了準備を経由して未確定の編集内容と保存キューを確定します。

## Desktopグローバルショートカット

macOSでは`⌘⌃`、Windowsでは`Ctrl+Alt`を修飾キーとして、Split、停止、再開、表示切り替え、メモ表示、Split選択をネイティブ登録します。設定画面の全体オン・オフは両OSに反映されます。

Windowsで他のアプリが同じキーを登録済みの場合、そのキーだけはOSによる登録に失敗する可能性があります。キー割り当ての変更はv1の対象外です。

## テストと静的解析

全テスト:

```bash
flutter test
```

実行順による依存がないことを確認するとき:

```bash
flutter test --test-randomize-ordering-seed=random
```

静的解析:

```bash
flutter analyze
```

差分の空白エラー確認:

```bash
git diff --check
```

保存処理のテストは一時ディレクトリを使用し、Widgetテストはメモリ上のストレージを注入します。テストから実際のユーザー用`sessions.json`へアクセスしてはいけません。

## 変更時の確認方針

- UIを変更するときは、旧SplitLogまたは現在の完成済みmacOS版を基準にする
- コアロジック変更時は、全体時間とSplit合計の整合性を確認する
- 保存変更時は、連続保存、読み込み中操作、終了直前保存、壊れたJSONをテストする
- Desktopネイティブ変更時は、通常のFlutterテストに加えて対象OSのReleaseビルドを実行する
- macOSまたはWindows固有の変更時も、共有Desktop UIと他方のOSを回帰させない
- モバイル対応時は、完成済みDesktop版の既存挙動を回帰させない
- Mobile UI変更時は、iPhone SE相当の小画面、キーボード表示、長いSplit名、複数Splitを確認する

Release作成の手順は[`release.md`](release.md)を参照してください。
