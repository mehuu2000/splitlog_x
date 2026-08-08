<p align="center">
  <img src="macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png" width="96" alt="SplitLog icon">
</p>

<h1 align="center">SplitLog</h1>

<p align="center">
  作業時間をSplit単位で記録し、メモとサマリーにまとめる常駐型タイムトラッカー
</p>

SplitLogは、作業セッションを細かなSplitに分けて時間とメモを記録するFlutterアプリです。macOS版はメニューバーに常駐し、必要なときだけ小さなウィンドウを開いて操作できます。

既存のSwift/AppKit版SplitLogを参照実装として、macOS、Windows、iPhone、Androidで同じ記録体験を提供することを目標に再構築しています。

## 対応状況

| プラットフォーム | 状況 | 提供形態 |
| --- | --- | --- |
| macOS | v1完成 | ZIPによる直接配布 |
| Windows | 開発予定 | ZIP、将来的にMSI/MSIX |
| iPhone | 開発予定 | TestFlight |
| Android | 開発予定 | APK |

現在、実用可能な対象はmacOS版です。Windows、iPhone、Androidの各プロジェクトは生成済みですが、常駐処理や各画面の実装・配布確認は今後行います。

## 主な機能

- macOSメニューバーへの常駐と、クリックによる表示・非表示
- セッションの追加、切り替え、名前編集、リセット、削除
- `開始`、`停止`、`再開`、`Split`による時間記録
- Split名の編集とSplitごとのメモ記録
- ラジオ方式・チェック方式による時間配分
- 作業時間を可視化するリング表示
- セッション内容からのサマリー生成、編集、コピー
- 標準・テンプレート・ユーザー定義のサマリーフォーマット
- カラー・モノクロテーマ、リング周期などの表示設定
- Popoverの前面固定と、外側クリックによる自動非表示
- 設定で有効・無効を切り替えられるグローバルショートカット
- ローカルJSONへの自動保存と旧SplitLogデータのインポート

## macOS版のインストール

動作対象はmacOS 10.15以降です。現在のReleaseビルドにはApple Silicon（arm64）版とIntel（x86_64）版の両方が含まれています。

1. 配布された`SplitLog-macOS-v1.0.0.zip`をダウンロードします。
2. ZIPを展開します。
3. `SplitLog.app`を`アプリケーション`フォルダへ移動します。
4. `SplitLog.app`を起動します。
5. 画面右上のメニューバーに表示されるタイマーアイコンをクリックします。

現行の身内向けZIPはMac App Store配布・Appleによる公証を行っていません。初回起動をmacOSに止められた場合は、`SplitLog.app`をControlキーを押しながらクリックし、`開く`を選択してください。

既存バージョンを更新するときは、SplitLogを終了してから`アプリケーション`フォルダ内のアプリを置き換えてください。通常、アプリを置き換えてもローカルのセッションデータは保持されます。

## 基本的な使い方

1. `開始`で計測を始めます。
2. 作業の区切りで`Split`を押します。
3. Split名をクリックして作業名を編集します。
4. ノートアイコンから、そのSplitのメモを記録します。
5. 必要に応じて`停止`と`再開`を使います。
6. ヘッダーのサマリーボタンから内容を確認・編集し、クリップボードへコピーします。

ウィンドウ外をクリックするとSplitLogは非表示になります。南京錠をオンにすると前面に固定され、外側をクリックしても閉じません。終了するときは、設定画面またはメニューバーのメニューから`SplitLogを終了`を選択してください。

## グローバルショートカット

| ショートカット | 操作 |
| --- | --- |
| `⌘⌃S` | Split |
| `⌘⌃X` | 停止 |
| `⌘⌃R` | 再開 |
| `⌘⌃V` | ウィンドウの表示・非表示 |
| `⌘⌃M` | 選択中Splitのメモを開く |
| `⌘⌃1` ... `⌘⌃9` | 指定位置のSplitを選択・切り替え |
| `⌘⌃0` | 最新のSplitを選択 |
| `⌘⌃↑` / `⌘⌃↓` | 選択するSplitを上下に移動 |

ショートカットは設定画面からまとめて無効にできます。キー割り当ての変更には対応していません。

## データとプライバシー

セッション、Split、メモ、設定は端末内の`sessions.json`に保存します。アカウント登録やクラウド同期は使用しません。

macOS版の主な保存先:

```text
~/Library/Containers/com.example.splitlogx/Data/Library/Application Support/SplitLog_x/sessions.json
```

旧Swift/AppKit版SplitLogがインストールされている場合は、起動時の確認画面または設定の`ストレージ管理`からデータをインポートできます。

## 開発を始める

```bash
git clone https://github.com/mehuu2000/splitlog_x.git
cd splitlog_x
flutter pub get
flutter run -d macos
```

必要な環境、プロジェクト構成、テスト方法は[`docs/development.md`](docs/development.md)を参照してください。

## ドキュメント

- [`docs/development.md`](docs/development.md): 開発環境、構成、保存、テスト
- [`docs/release.md`](docs/release.md): ビルド、ZIP作成、配布手順
- [`plan.md`](plan.md): クロスプラットフォーム対応方針とロードマップ

## ロードマップ

1. macOS版v1: 完了
2. Windows版: Desktop UIを共有し、タスクトレイ常駐と配布を実装
3. iPhone/Android版: 縦画面向けUIと復帰時の正確な時間復元を実装
4. 必要性を確認したうえで、通知・同期・ストア配布を検討

詳細は[`plan.md`](plan.md)に記録しています。
