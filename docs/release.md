# SplitLog Release Guide

## この文書について

この文書は、SplitLogの配布物を作成・確認するための手順です。

現在確立しているのは、macOS版をReleaseビルドし、身内向けのZIPとして直接配布する手順です。Mac App Store提出、Developer ID署名、公証、Windows、iPhone、Androidの配布手順は未確定です。

## バージョン

アプリのバージョンとビルド番号は`pubspec.yaml`で管理します。

```yaml
version: 1.0.0+1
```

- `1.0.0`: ユーザーへ表示するバージョン
- `1`: プラットフォームで使用するビルド番号

配布前に、ZIP名と`pubspec.yaml`のバージョンが一致していることを確認してください。

## リリース前確認

依存関係を取得します。

```bash
flutter pub get
```

テストと静的解析を実行します。

```bash
flutter test --test-randomize-ordering-seed=random
flutter analyze
git diff --check
```

実機で最低限、次の操作を確認します。

- 起動とメニューバーアイコン表示
- ウィンドウの表示・非表示とロック
- 開始、停止、再開、Split
- Split名とメモの編集
- セッション追加と切り替え
- サマリー生成、編集、コピー
- 設定変更後の再起動復元
- 設定、メニューバー、`⌘Q`からの終了

確認時に個人の実データを使う場合は、事前に`sessions.json`をバックアップしてください。

## macOS Releaseビルド

プロジェクトルートで実行します。

```bash
flutter build macos --release
```

生成されるアプリ:

```text
build/macos/Build/Products/Release/SplitLog.app
```

ビルドしたアプリを起動して確認します。

```bash
open build/macos/Build/Products/Release/SplitLog.app
```

現在のビルドがApple SiliconとIntelの両方を含むか確認する場合:

```bash
file build/macos/Build/Products/Release/SplitLog.app/Contents/MacOS/SplitLog
```

## ZIP作成

バージョンを指定し、配布先の`dist`ディレクトリへZIPを作成します。次のコマンドは同じターミナルでまとめて実行してください。

```bash
VERSION=1.0.0
mkdir -p dist
rm -f "dist/SplitLog-macOS-v${VERSION}.zip"

ditto -c -k --sequesterRsrc --keepParent \
  build/macos/Build/Products/Release/SplitLog.app \
  "dist/SplitLog-macOS-v${VERSION}.zip"

ls -lh "dist/SplitLog-macOS-v${VERSION}.zip"
shasum -a 256 "dist/SplitLog-macOS-v${VERSION}.zip"
```

同じバージョンの古いZIPを削除してから、macOSの属性を維持できる`ditto`で圧縮しています。`rm -f`が削除するのは指定した古いZIPだけで、アプリ本体、ソースコード、ユーザーデータには影響しません。

SHA-256チェックサムはストア提出には通常使用しません。直接配布したファイルの破損・差し替え確認や、配布記録として必要な場合に保存します。

## 配布時の注意

現行のZIPは、Mac App Store配布とAppleによる公証を行っていません。

受け取ったユーザーには次の手順を案内します。

1. ZIPを展開する
2. `SplitLog.app`を`アプリケーション`フォルダへ移動する
3. 初回起動を止められた場合は、Controlキーを押しながらアプリをクリックする
4. `開く`を選択する

既存版を更新するときは、先にSplitLogを終了してからアプリを置き換えます。セッションデータはアプリ本体とは別のコンテナに保存されるため、通常のアプリ更新では削除されません。

## 現在の配布状況

| プラットフォーム | 現在の手順 | 今後の候補 |
| --- | --- | --- |
| macOS | ReleaseビルドをZIPで直接配布 | DMG、Developer ID署名、公証 |
| Windows | 未実装 | ZIP、MSI/MSIX |
| iPhone | 未実装 | TestFlight |
| Android | 未実装 | APK、必要に応じてGoogle Play |

未確定のプラットフォームについて、検証前のコマンドや署名手順をこの文書へ推測で追加しないでください。実機ビルドと配布確認が完了した時点で追記します。

## リリースチェックリスト

- [ ] `pubspec.yaml`のバージョンを確認した
- [ ] `flutter test`が成功した
- [ ] `flutter analyze`が成功した
- [ ] `git diff --check`が成功した
- [ ] Releaseビルドが成功した
- [ ] Release版で主要操作を確認した
- [ ] ZIP名とアプリバージョンが一致している
- [ ] ZIPを展開して`SplitLog.app`が含まれることを確認した
- [ ] 必要に応じてSHA-256を記録した
