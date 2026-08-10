# SplitLog Release Guide

## この文書について

この文書は、SplitLogの配布物を作成・確認するための手順です。

現在確立しているのは、macOS版とWindows版をReleaseビルドし、身内向けのZIPとして直接配布する手順です。iPhoneとAndroidはMobile用エントリーポイントによるDebugビルドとSimulator/Emulator表示を確認済みです。Mac App Store提出、Developer ID署名、公証、Windowsインストーラー、TestFlight、Release APKの配布手順は未確定です。

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

対象OSの実機で最低限、次の操作を確認します。

- 起動とメニューバー/タスクトレイアイコン表示
- ウィンドウの表示・非表示とロック
- 開始、停止、再開、Split
- Split名とメモの編集
- セッション追加と切り替え
- サマリー生成、編集、コピー
- 設定変更後の再起動復元
- グローバルショートカット
- 設定と常駐アイコンのメニューからの終了

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

## macOS ZIP作成

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

## macOS配布時の注意

現行のZIPは、Mac App Store配布とAppleによる公証を行っていません。

受け取ったユーザーには次の手順を案内します。

1. ZIPを展開する
2. `SplitLog.app`を`アプリケーション`フォルダへ移動する
3. 初回起動を止められた場合は、Controlキーを押しながらアプリをクリックする
4. `開く`を選択する

既存版を更新するときは、先にSplitLogを終了してからアプリを置き換えます。セッションデータはアプリ本体とは別のコンテナに保存されるため、通常のアプリ更新では削除されません。

## Windows Releaseビルド

WindowsのPowerShellでプロジェクトルートから実行します。

```powershell
flutter build windows --release
```

x64ビルドの生成先:

```text
build\windows\x64\runner\Release
```

`Release`には`SplitLog.exe`だけでなく、`flutter_windows.dll`と`data`フォルダが生成されます。配布時はこれらを分離せず、同じ構成のまま含めてください。

## Windows ZIP作成

現在のWindows ZIPは、Visual C++ランタイムをアプリと同じフォルダへ含めるapplication-local方式です。次のスクリプトはVisual Studio Community 2022を使用する現在の開発環境向けです。別のEditionまたはインストール先を使用する場合は`$VS_ROOT`を合わせて変更してください。

```powershell
$VERSION = "1.0.0"
$RELEASE = Join-Path $PWD.Path "build\windows\x64\runner\Release"
$DIST = Join-Path $PWD.Path "dist"
$ZIP_NAME = "SplitLog-Windows-v$VERSION.zip"
$ZIP = Join-Path $DIST $ZIP_NAME

if (!(Test-Path (Join-Path $RELEASE "SplitLog.exe"))) {
    throw "SplitLog.exeが見つかりません: $RELEASE"
}

if (!(Test-Path (Join-Path $RELEASE "flutter_windows.dll"))) {
    throw "flutter_windows.dllが見つかりません"
}

if (!(Test-Path (Join-Path $RELEASE "data"))) {
    throw "dataフォルダが見つかりません"
}

$VS_ROOT = Join-Path $env:ProgramFiles "Microsoft Visual Studio\2022\Community"
$REDIST_ROOT = Join-Path $VS_ROOT "VC\Redist\MSVC"

$REDIST_DIR = Get-ChildItem -Path $REDIST_ROOT -Directory -Recurse |
    Where-Object {
        $_.FullName -match '\\x64\\Microsoft\.VC\d+\.CRT$' -and
        (Test-Path (Join-Path $_.FullName "msvcp140.dll"))
    } |
    Sort-Object FullName -Descending |
    Select-Object -First 1

if ($null -eq $REDIST_DIR) {
    throw "Visual C++ランタイムが見つかりません: $REDIST_ROOT"
}

$RUNTIME_DLLS = @(
    "msvcp140.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll"
)

foreach ($DLL in $RUNTIME_DLLS) {
    $SOURCE = Join-Path $REDIST_DIR.FullName $DLL
    if (!(Test-Path $SOURCE)) {
        throw "$DLL が見つかりません: $SOURCE"
    }
    Copy-Item -LiteralPath $SOURCE -Destination $RELEASE -Force
}

New-Item -ItemType Directory -Path $DIST -Force | Out-Null
Remove-Item -LiteralPath $ZIP -Force -ErrorAction SilentlyContinue

Compress-Archive `
    -Path (Join-Path $RELEASE "*") `
    -DestinationPath $ZIP `
    -CompressionLevel Optimal

Get-Item $ZIP
Get-FileHash $ZIP -Algorithm SHA256
```

v1.0.0で確認済みのSHA-256:

```text
AF4E2476428C8F866E07B66E9FC6C24258639FA35984125D3A75F982E9CB30C7
```

配布前に、ZIPを元のビルドフォルダとは別の一時フォルダへ展開して起動します。

```powershell
$CHECK_DIR = Join-Path $env:TEMP "SplitLog-Windows-v$VERSION-check"

Remove-Item -LiteralPath $CHECK_DIR -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath $ZIP -DestinationPath $CHECK_DIR

Start-Process `
    -FilePath (Join-Path $CHECK_DIR "SplitLog.exe") `
    -Wait
```

`-Wait`はSplitLogを明示的に終了するまでPowerShellを待機させます。起動後は、タスクトレイアイコン、主要操作、データ保存、明示的終了を確認してください。

## Windows配布時の注意

受け取ったユーザーには次の手順を案内します。

1. ZIP全体を任意のフォルダへ展開する
2. 展開先の`SplitLog.exe`を起動する
3. Windows Defender SmartScreenが表示された場合は、配布元を確認してから`詳細情報`を開く
4. タスクトレイのSplitLogアイコンからウィンドウを表示する

`SplitLog.exe`だけを移動すると、FlutterとVisual C++のDLLまたは`data`が見つからず起動できません。移動・保管するときは展開先のフォルダ一式を扱ってください。セッションデータは`%LOCALAPPDATA%\SplitLog`へ保存されるため、配布フォルダの置き換えでは通常削除されません。

## 現在の配布状況

| プラットフォーム | 現在の手順 | 今後の候補 |
| --- | --- | --- |
| macOS | ReleaseビルドをZIPで直接配布 | DMG、Developer ID署名、公証 |
| Windows | ReleaseビルドをZIPで直接配布 | MSI/MSIX、コード署名 |
| iPhone | Mobile UI・Simulator Debugビルド・大小画面確認済み | 実機検証、TestFlight |
| Android | Mobile UI・Debug APKビルド・Emulator大小画面確認済み | 実機検証、署名済みAPK、必要に応じてGoogle Play |

未確定のプラットフォームについて、検証前のコマンドや署名手順をこの文書へ推測で追加しないでください。実機ビルドと配布確認が完了した時点で追記します。

## リリースチェックリスト

- [ ] `pubspec.yaml`のバージョンを確認した
- [ ] `flutter test`が成功した
- [ ] `flutter analyze`が成功した
- [ ] `git diff --check`が成功した
- [ ] Releaseビルドが成功した
- [ ] Release版で主要操作を確認した
- [ ] ZIP名とアプリバージョンが一致している
- [ ] ZIPを別の場所へ展開してRelease版を起動した
- [ ] macOSでは`SplitLog.app`が含まれることを確認した
- [ ] Windowsでは`SplitLog.exe`、必要なDLL、`data`が含まれることを確認した
- [ ] 必要に応じてSHA-256を記録した
