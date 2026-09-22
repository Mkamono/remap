# remap

macOS 用の自前キーリマッパー。[Karabiner-Elements](https://karabiner-elements.pqrs.org/) の設定を、依存ライブラリなしの軽量な常駐アプリで再現します。

- **Swift 単一ファイル + `CGEventTap`** によるネイティブ実装
- カーネル拡張・ドライバ不要。**アクセシビリティ権限のみ**で動作
- メニューバー常駐（Dock アイコンなし）
- 設定ファイルを保存すると即時反映

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
| RShift + ; + E/D/S/F | スクロール |
| RShift + J / K / L | 左 / 中 / 右クリック |
| RShift + N | 速度 2倍 |
| RShift + M | 低速モード。押し始めは極低速で、動かし続けると通常速度まで徐々に加速 |

## 必要環境

- macOS 13 以降
- Apple Silicon
- Accessibility 権限

ローカルビルドには Xcode Command Line Tools（`swiftc`）も必要です。

## 配布モデル

remap 自身は「起動されたら常駐してリマップを提供する」ことだけを担当します。
インストール先やログイン時自動起動は、マシン設定側（例: mise の bootstrap）で管理する想定です。

`vX.Y.Z` tag を push すると GitHub Actions が以下を行います。

1. arm64 向け `remap.app` をビルド
2. ad-hoc code signing
3. `remap-<version>-arm64.zip` と SHA-256 を GitHub Release に公開
4. その Release を参照する `mise.example.toml` を main に更新

`mise.example.toml` には、`/Applications/remap.app` へのインストールと、任意の LaunchAgent 設定が含まれます。

> GitHub Releases のビルドは Developer ID 署名・notarization を行いません。初回起動時の Gatekeeper 操作や Accessibility 許可は手動で必要です。また ad-hoc 署名のため、アプリ更新後に Accessibility の再許可が必要になる場合があります。

## ローカルビルド

```sh
./scripts/build-app.sh
open dist/remap.app
```

成果物は `dist/remap.app` に生成されます。

ローカルの Keychain に code-signing identity `remap-signing` が存在する場合はそれを使って署名し、存在しなければ ad-hoc 署名へフォールバックします。別名を使う場合は `SIGN_IDENTITY` を指定できます。

```sh
SIGN_IDENTITY=my-signing bash scripts/build-app.sh
```

安定したローカル署名 identity を使うと、同じ Mac 上での再ビルド時に Accessibility 権限を維持しやすくなります。

## Accessibility 権限

初回起動時に **システム設定 → プライバシーとセキュリティ → アクセシビリティ** で `remap` を許可してください。

権限が未付与の場合、remap は許可状態を監視し、許可された時点で `CGEventTap` を開始します。

## 設定

設定は次の JSON ファイルです。

```text
~/.config/remap/config.json
```

ファイルが無ければ初回起動時にデフォルトを生成します。保存すると再起動なしで反映されます。

```json
{
  "mouse": {
    "baseSpeed": 1536,
    "scrollSpeed": 32,
    "tickHz": 60,
    "slowMinMultiplier": 0.04,
    "slowMaxMultiplier": 1.0,
    "slowRampSeconds": 1.5,
    "fastMultiplier": 2.0
  },
  "mouseMode": {
    "modeKey": "right_shift",
    "moveUp": "e",
    "moveDown": "d",
    "moveLeft": "s",
    "moveRight": "f",
    "scroll": "semicolon",
    "fast": "n",
    "slow": "m",
    "leftClick": "j",
    "middleClick": "k",
    "rightClick": "l"
  },
  "remap": {
    "modifier": "control",
    "bindings": {
      "e": "up",
      "d": "down",
      "s": "left",
      "f": "right",
      "left_bracket": "escape",
      "h": "delete"
    }
  },
  "capsLock": {
    "remapToControl": true
  }
}
```

キーは名前で指定します（`a`〜`z` / `0`〜`9` / 記号 / `up`・`down`・`escape`・`delete`・`tab`・`space` / `right_shift`・`right_command` など）。

## 仕組み

- **Caps Lock** は `CGEventTap` ではなく `hidutil` で Left Control にリマップします。
- その他のキー入力は `CGEventTap`（`cgSessionEventTap`）で処理します。
- カーソルの連続移動はタイマーで座標を更新します。
- 文字ではなく仮想 keyCode で判定するため、キーボード配列に依存しません。
- `LSUIElement=true` / `.accessory` の通常の AppKit アプリとして常駐します。LaunchAgent の生成・管理はアプリ自身では行いません。
