# remap

macOS 用の自前キーリマッパー。[Karabiner-Elements](https://karabiner-elements.pqrs.org/) の設定を、依存ライブラリなしの軽量な常駐アプリで再現します。

- **Swift 単一ファイル + `CGEventTap`** によるネイティブ実装
- カーネル拡張・ドライバ不要。**アクセシビリティ権限のみ**で動作
- メニューバー常駐（Dock アイコンなし）／ログイン時自動起動

## 機能

### キーリマップ
| 入力 | 出力 |
|------|------|
| Caps Lock | Left Control |
| Ctrl + E / D / S / F | ↑ / ↓ / ← / → |
| Ctrl + [ | Esc |
| Ctrl + H | Backspace |

修飾キーは透過するので、例えば `Ctrl + Shift + F` は `Shift + →`（範囲選択）になります。
一度リマップされたキーは、修飾キーを先に離しても、その物理キーを離すまで素の文字が入力されません。

### マウスフルエミュレーション（Right Shift を押している間）
| 入力 | 動作 |
|------|------|
| RShift + E / D / S / F | カーソル移動（上 / 下 / 左 / 右、押している間連続） |
| RShift + ; + E/D/S/F | スクロール（; を併用している間） |
| RShift + J / K / L | 左 / 中 / 右クリック |
| RShift + N | 速度 2倍（押している間） |
| RShift + M | 低速モード。M は押しっぱなしでよく、方向キーを押し始めた直後が極低速（小さなボタンの微調整向け）、動かし続けると約2.5秒かけて通常速度まで徐々に加速。方向キーを離して押し直すとまた最遅から |

## 必要環境

- macOS 13 以降
- Xcode Command Line Tools（`swiftc` が使えればOK。`xcode-select --install`）

## インストール

```sh
sh install.sh
```

ビルドして LaunchAgent に登録し、起動します。初回のみ **システム設定 → プライバシーとセキュリティ → アクセシビリティ** で `remap` を許可してください（許可した瞬間に自動で有効化されます。再起動不要）。

以降はログインのたびに自動で常駐します。メニューバーの ⌨ アイコンから ON/OFF・終了ができます。

## アンインストール

```sh
sh uninstall.sh
```

自動起動の解除・常駐停止・Caps Lock の復元を行います。アクセシビリティ権限の登録も消す場合は `tccutil reset Accessibility com.local.remap`。

## カスタマイズ

- **キー割り当て**: `src/main.swift` の `staticRemap` / `routeMouse` を編集。
- **マウス速度・スクロール量**: `MouseEngine` 冒頭の `baseSpeed`（px/秒）・`scrollSpeed` を調整。
- **低速モード(M)のランプ**: `slowMinMultiplier`（押し始めの速度）・`slowMaxMultiplier`（到達速度）・`slowRampSeconds`（加速にかける秒数）を調整。

変更後は `sh install.sh` を再実行すれば反映されます。

## 仕組みのメモ

- **Caps Lock** は HID レベルの特殊扱いのため、`CGEventTap` ではなく `hidutil` で Left Control にリマップします（起動時に適用、終了時に復元）。
- イベントは `CGEventTap`（`cgSessionEventTap`）で購読し、リマップ対象は keyCode を差し替えて出力、マウス操作系は消費して内部エンジンへ渡します。
- カーソルの連続移動は ~60Hz のタイマーで座標を更新して実現しています。
- 配列非依存: 文字ではなく **keyCode（仮想キーコード）** で判定するため、JIS の Mac に US 配列キーボードを繋いでも US 側でそのまま動作します。

## 開発

不具合調査時は `src/main.swift` の `remapDebug` を `true` にし、ターミナルから直接起動するとイベントログが見えます:

```sh
./remap.app/Contents/MacOS/remap
```

`Ctrl+C` で終了すると Caps Lock も元に戻ります。

> **署名について**: `build.sh` は adhoc 署名にフォールバックします。adhoc 署名は再ビルドのたびに署名ハッシュが変わり、アクセシビリティ権限が外れます。`install.sh` は内部で権限をリセットするので、再ビルド後は許可し直してください。再付与を恒久的に無くしたい場合は、Keychain Access で自己署名コード署名証明書 `remap-signing` を作成すると、`build.sh` が自動でそれを使い権限が維持されます。
