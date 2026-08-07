# SplitLog Development Guide

## この文書について

この文書は、SplitLogの開発環境を準備し、実装・検証を行う開発者向けのガイドです。

現在完成しているのはmacOS版v1です。Windows、iPhone、AndroidはFlutterプロジェクトのみ生成済みで、プラットフォーム固有処理と画面の実装は今後行います。

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

実行中のターミナルでは、次のキーを使用できます。

| キー | 操作 |
| --- | --- |
| `r` | ホットリロード |
| `R` | ホットリスタート |
| `q` | アプリを終了 |

ネイティブのSwiftコード、アプリアイコン、entitlementsなどを変更した場合は、ホットリロードでは反映されません。実行中のアプリを終了してから再ビルドしてください。

## プロジェクト構成

```text
lib/
  main.dart
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

macos/Runner/
  AppDelegate.swift
  MainFlutterWindow.swift

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
| `macos/Runner` | メニューバー、ウィンドウ、ショートカットなどのmacOS処理 |
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

保存時は次の順番で処理します。

1. 保存要求をキューへ追加する
2. JSON全体を`sessions.json.tmp`へ書き込む
3. 書き込み完了後に`sessions.json`へ置き換える
4. 終了時は保存キューの完了を待つ

この構成により、短時間の複数保存による順序逆転と、書き込み途中の終了によるJSON破損を抑えます。読み込み不能な既存JSONを検出した場合は、元ファイルを保護するため自動保存を停止します。

端末間同期、アカウント、ネットワーク上のDBは使用しません。

## 旧SplitLogデータの移行

旧Swift/AppKit版の`sessions.json`を、現在の保存スナップショットへ変換できます。

- macOSでは旧版の既知の保存先を起動時に検知する
- 検知しても自動取り込みはせず、ユーザー確認を挟む
- 設定画面から旧データの検知を再実行できる
- ファイル選択ダイアログから`sessions.json`を手動指定できる
- Windowsでは自動検知を行わず、手動指定のみ対応する予定

移行処理を変更するときは、現行JSONの読み込みと旧JSONの変換を混同しないようにしてください。

## macOSネイティブ連携

DartとSwiftは`splitlog_x/app`という`MethodChannel`で連携します。

DartからmacOS:

| メソッド | 用途 |
| --- | --- |
| `quitApp` | 保存完了後にアプリを終了 |
| `setShortcutsEnabled` | グローバルショートカットの有効・無効 |
| `setPopoverLocked` | ウィンドウの前面固定 |
| `chooseLegacyFile` | 旧`sessions.json`の選択と読み込み |
| `openContact` | メールアプリを開く |

macOSからDart:

| メソッド | 用途 |
| --- | --- |
| `shortcutAction` | グローバルショートカットの操作をDartへ通知 |
| `prepareToQuit` | 編集確定と保存完了を待ってから終了可否を返す |

設定画面、メニューバーメニュー、`⌘Q`の終了要求は、すべて`prepareToQuit`を経由して未確定の編集内容を保存します。

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
- macOSネイティブ変更時は、通常のFlutterテストに加えてReleaseビルドを実行する
- Windows・モバイル対応では、macOS版の既存挙動を回帰させない

Release作成の手順は[`release.md`](release.md)を参照してください。
