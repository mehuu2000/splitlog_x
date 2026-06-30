# SplitLog Flutter Rebuild Plan

## 目的

既存のmacOS版SplitLogを参照実装として、FlutterでmacOS、Windows、iPhone、Android向けに再構築する。

既存のSwift/AppKit版は直接変更しない。Flutter版は `/Users/hamada/projects/splitlog_x` の独立プロジェクトとして開発する。

## 対象プラットフォーム

- macOS
- Windows
- iPhone
- Android

## 基本方針

### PC版

macOS版とWindows版は、既存macOS版SplitLogのUI/UXをほぼ完全再現する。

- macOSはメニューバー常駐アプリとして扱う
- Windowsはタスクトレイ常駐アプリとして扱う
- クリック時に小型のポップアップ風ウィンドウを表示する
- 表示サイズ、情報密度、主要操作、操作導線は既存macOS版を基準にする
- DB、保存方式、実装技術の変更は許容する
- ただし、ユーザーから見える挙動は可能な限り既存版に揃える
- ウィンドウを閉じた場合はアプリ終了ではなく非表示にする
- アプリ終了は設定またはメニューから明示的に実行する
- グローバルショートカットはDesktop版のみ再現対象にする
- グローバルショートカットは設定から全体オン/オフできるようにする
- ショートカットのキー割り当て変更はv1では対象外にする

### スマートフォン版

iPhone版とAndroid版は、一般的な全画面アプリとして提供する。

- 横長Popover前提のレイアウトは使わない
- 縦長画面に合わせてコンポーネントの配置を再設計する
- 色、部品の意味、操作概念、情報の優先順位は既存macOS版をできるだけ維持する
- UIを完全に別物にせず、既存SplitLogの見た目と体験を保つ
- 片手操作、画面幅、タッチ操作に合わせてUXを調整する
- 画面向きは縦固定にする
- 常時バックグラウンド実行を前提にしない
- 計測中に別アプリへ切り替えた場合も、開始時刻と現在時刻の差分からタイマーが継続しているように復元する
- 必要に応じてローカル通知を使うが、v1では常駐サービス前提にはしない

## 共有するもの

以下はプラットフォーム共通のDartコードとして実装する。

- セッションモデル
- Split/Lapモデル
- ストップウォッチ状態管理
- Split配分モード
- サマリー生成
- 設定値
- 保存データのスキーマ
- 時間計算
- バリデーション

## プラットフォーム別に分けるもの

以下はプラットフォーム別に実装または分岐する。

- アプリ起動方式
- 常駐方式
- ウィンドウ制御
- メニューバー/タスクトレイ制御
- クリップボード
- ファイル保存先
- 通知
- ショートカット
- 配布/ビルド設定
- 画面レイアウト

## UI方針

既存リポジトリ内の `SplitLog/sample/*.png` は旧SplitLog制作時の参考画像であり、完成版UIとは異なるため、Flutter版の再現基準には使わない。

見た目の基準は、可能であれば旧macOS版を実行して取得したスクリーンショットとする。旧macOS版を実行できない場合は、SwiftUI/AppKitコードから現状UIを読み取り、FlutterのDesktop UIとMobile UIへ再構築する。

挙動の基準は、既存SwiftコードとREADMEとする。

### Desktop UI

Desktop UIは既存macOS版の再現を最優先する。

- 既存のPopoverサイズ感を基準にする
- セッションタイトル、リング、Splitリスト、操作ボタン、設定、サマリーの位置関係を維持する
- macOS版とWindows版は原則同じDesktop UIを使う
- OS固有の見た目差は必要最小限にする

### Mobile UI

Mobile UIはDesktop UIの情報設計を保ちつつ、縦長画面に再配置する。

- 上部にセッション情報と主要状態を配置する
- 中央にリング/経過時間などの視覚情報を配置する
- Splitリストは縦スクロールを前提にする
- 開始、停止、再開、Splitなどの主要操作は親指で触りやすい位置に置く
- 設定、サマリー、ヘルプはモーダルまたは別画面として整理する

## データ保存と移行方針

### 保存方式

v1ではネットワークを使わず、端末ローカル保存のみとする。

- セッション/Split/LapデータはJSONファイルで保存する
- 設定はFlutterのローカル設定保存、または設定JSONで保存する
- SQLiteなどのDBはv1では使わない
- データ量や検索要件が増えた場合のみ、将来的にSQLiteを検討する
- クラウド同期はv1では実装しない
- 同期が必要になった場合は将来機能として検討する

### 旧SplitLogデータ移行

旧macOS版の `sessions.json` とはできるだけ互換を持たせる。

移行方式:

- 基本はユーザーが `sessions.json` を選択する手動インポートとする
- macOS版のみ、旧SplitLogの標準保存先を検知できる場合は確認ダイアログを表示する
- 自動検知した場合も勝手に取り込まず、必ずユーザー確認後にインポートする
- 旧データで既存Flutterデータを上書きする場合は、明示的な確認を挟む
- 設定データは完全互換を必須にせず、必要に応じて移行対象を絞る

旧SplitLogの主な保存先:

```text
~/Library/Containers/hamachi.SplitLog/Data/Library/Application Support/SplitLog/sessions.json
~/Library/Containers/hamachi.SplitLog/Data/Library/Preferences/hamachi.SplitLog.plist
```

## モバイルのバックグラウンド方針

ユーザー体験としては、別アプリへ切り替えてもタイマーが継続しているように見せる。

実装方針:

- 計測開始時刻、停止時刻、累積時間、状態を保存する
- アプリがフォアグラウンドに戻ったとき、保存時刻と現在時刻の差分で表示を復元する
- iOS/Androidで毎秒処理を動かし続ける設計にはしない
- iOSでは必要に応じてローカル通知を使う
- Androidでは将来的に必要になった場合のみ、フォアグラウンドサービスと常駐通知を検討する
- v1ではバックグラウンド常駐よりも、復帰時の正確な時間復元を優先する
- v1では通知欄やロック画面に「SplitLog計測中」を常時表示する機能は実装しない
- iOS Live ActivitiesやAndroid Foreground Serviceは後続機能として扱う

## 配布方針

- macOS: zip/dmg配布
- Windows: zip/msi配布
- iOS: TestFlight
- Android: APK直接配布

ストア配布はv1の必須要件にはしない。

## 実装構成方針

想定ディレクトリ構成:

```text
lib/
  main.dart
  app/
    splitlog_app.dart
    platform_shell.dart
  core/
    models/
    services/
    stores/
    formatters/
  features/
    session/
      state/
      widgets/
      desktop/
      mobile/
    settings/
    summary/
  platform/
    desktop/
    mobile/
```

方針:

- ロジックは `core` に集約する
- 機能単位のUIは `features` に置く
- Desktop専用UIとMobile専用UIは分ける
- OS API依存は `platform` に閉じ込める
- `Platform.isMacOS` や `Platform.isWindows` の直接分岐をUI全体に散らさない

## 既存macOS版から再現する主要機能

- メニューバー/タスクトレイからすぐ開ける軽量UI
- セッションの追加、切り替え、削除
- 開始、停止、再開、Splitによる時間記録
- Splitごとの名前編集
- Splitごとのメモ記録
- サマリー生成
- サマリーコピー
- Popover/小型ウィンドウのロック相当機能
- 表示設定
- カラー/モノクロテーマ
- リング周期設定
- Split配分モード切り替え
- 新規セッション用デフォルト配分モード
- データ管理
- 操作説明
- お問い合わせ導線

## 開発順序

### Step 1

まず旧SplitLogのDesktop版再現を行う。

1. 旧SplitLogのUI/機能を棚卸しする
2. Desktop静的UIをFlutterで再現する
3. コアモデル/タイマーロジックを実装する
4. UIとロジックを接続する
5. macOSメニューバー常駐/小型ウィンドウ化を実装する
6. JSON保存と旧 `sessions.json` インポートを実装する
7. macOS版の完成度チェックと残タスク整理を行う
8. macOS版の表示名とアプリアイコンを整備する

Step 1-7の結果は `docs/step1_7_review.md` に記録する。

Step 1-7で見つかったサマリー動的生成/コピー、グローバルショートカット、手動ファイル選択インポート、お問い合わせ導線は修正済み。
Step 1-8でmacOS版の表示名を `SplitLog` に変更し、旧SplitLogのAppIconを移植済み。
ユーザー確認で追加修正がなければ、Step 1は完了扱いにする。

### Step 2以降

1. Windowsタスクトレイ/ポップアップ表示を実装する
2. Mobile UIの縦長レイアウトを作る
3. iPhone/Android向けの状態管理と操作を接続する
4. 各プラットフォームでビルド確認する
5. 配布形式を整理する

## 実装前の制約

- 既存 `/Users/hamada/projects/SplitLog` は原則変更しない
- 既存版は参照実装として扱う
- Flutter版の実装は `/Users/hamada/projects/splitlog_x` で行う
- 方針確定までは実装に入らない
- UI/UXの再現度を優先し、内部実装の完全一致は求めない
