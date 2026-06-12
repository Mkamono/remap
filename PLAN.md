# remap — macOS キーリマッパー 実装計画

Karabiner-Elements の設定を、自前の軽量な常駐ツールで再現する。
Swift + CGEventTap によるネイティブ実装。

---

## 1. ゴール

既存の Karabiner プロファイルと同等の挙動を、単一の Swift バイナリで実現する。

- 依存ライブラリなし（標準フレームワークのみ: `CoreGraphics`, `ApplicationServices`, `Foundation`）
- 単一ファイルを `swiftc` でビルドして常駐
- アクセシビリティ権限のみで動作（カーネル拡張やドライバ不要）

---

## 2. 再現する機能

### 2-1. Caps Lock → Left Control
- **方式（決定）**: アプリ起動時に `hidutil property --set` を自動実行してリマップ。終了時に解除して元に戻す。
- 理由: 自己完結し、ユーザーの手動設定が不要。Caps Lock は HID レベルの特殊扱いで CGEventTap で安定して捌きにくいため、HID リマップに寄せる。
- リマップ後は Caps Lock が HID 段階で Left Control になるため、後段の CGEventTap は「Left Control + ESDF」として透過的に処理できる。

### 2-2. 矢印キー（Left Control + ESDF）
| 入力 | 出力 |
|------|------|
| `Ctrl + E` | ↑ Up |
| `Ctrl + D` | ↓ Down |
| `Ctrl + S` | ← Left |
| `Ctrl + F` | → Right |

- mandatory: `left_control`、optional: `any`（他の修飾キーは透過し、矢印キーに引き継ぐ）。
- 例: `Ctrl + Shift + F` → `Shift + Right`（範囲選択）。

### 2-3. ESC と Delete（Left Control + 記号/H）
| 入力 | 出力 |
|------|------|
| `Ctrl + [` | Esc |
| `Ctrl + H` | Backspace (delete_or_backspace) |

- 同じく optional `any` で他修飾キーを透過。

### 2-4. マウスフルエミュレーション（Right Shift）

Right Shift を「モードキー」として使う。**押している間**だけマウス操作が有効。

#### アーミング
- Right Shift 単体: そのまま Right Shift として透過しつつ、キーアップ時に内部フラグ `mouseMode` を有効化（Karabiner の `mouse_keys_full = 1` 相当）。
- 実装上は「Right Shift が物理的に押されている間 = マウスモード」として単純化してよい。

#### カーソル移動（Right Shift + ESDF）
| 入力 | 動作 |
|------|------|
| `RShift + E` | カーソル上へ移動 |
| `RShift + D` | カーソル下へ移動 |
| `RShift + S` | カーソル左へ移動 |
| `RShift + F` | カーソル右へ移動 |

- Karabiner の値: ±1536（1秒あたりの速度）。**キーを押し続けている間、連続的に移動**する。
- → タイマー（または専用スレッド）で一定間隔ごとにカーソル位置を更新する必要がある。

#### スクロール（Right Shift + ; を併用）
- `RShift + ;`（semicolon）を**押している間**だけスクロールモード（`mouse_keys_full_scroll = 1`）。
- その状態で ESDF を押すとカーソル移動の代わりにホイールスクロール:

| 入力 | 動作 |
|------|------|
| `RShift + ; + E` | 上スクロール |
| `RShift + ; + D` | 下スクロール |
| `RShift + ; + S` | 左スクロール |
| `RShift + ; + F` | 右スクロール |

#### クリック（Right Shift + JKL）
| 入力 | 動作 |
|------|------|
| `RShift + J` | 左クリック (button1) |
| `RShift + K` | 中クリック (button3) |
| `RShift + L` | 右クリック (button2) |

#### 速度調整（Right Shift + NM）
| 入力 | 動作 |
|------|------|
| `RShift + N` | 速度 2倍（押している間） |
| `RShift + M` | 速度 0.3倍（押している間） |

---

## 3. アーキテクチャ

```
┌─────────────────────────────────────────────┐
│  main.swift                                  │
│                                              │
│  ┌────────────┐   tap    ┌────────────────┐  │
│  │ CGEventTap │ ───────► │  EventHandler  │  │
│  │ (keyDown,  │          │  - 修飾キー判定 │  │
│  │  keyUp,    │ ◄─────── │  - リマップ表   │  │
│  │  flagsChg) │  consume │  - モード状態   │  │
│  └────────────┘  /pass   └───────┬────────┘  │
│                                  │           │
│                          ┌───────▼────────┐  │
│                          │  MouseEngine   │  │
│                          │  - 移動タイマー │  │
│                          │  - スクロール   │  │
│                          │  - クリック     │  │
│                          └────────────────┘  │
└─────────────────────────────────────────────┘
```

### コンポーネント
- **EventTap 層**: `CGEvent.tapCreate` で keyDown / keyUp / flagsChanged を購読。`CFRunLoop` に組み込む。
- **EventHandler**: イベントを受け取り、
  - リマップ対象なら差し替えイベントを生成して `nil` を返す（元イベントを消費）。
  - 対象外ならそのまま通す。
- **MouseEngine**: マウス移動は押下中の連続動作なので、押されている方向キーの集合を保持し、`Timer`（または `DispatchSourceTimer`）で約 60Hz でカーソル位置を更新。

### 状態（内部フラグ）
- `mouseMode: Bool` — Right Shift 押下中か
- `scrollMode: Bool` — semicolon 押下中か
- `speedMultiplier: Double` — N/M による倍率（既定 1.0）
- `activeMoveKeys: Set<Direction>` — 現在押されている ESDF 方向

---

## 4. キーコード対応表（参考）

CGEvent の keyCode（ANSI 配列、`kVK_ANSI_*`）:

| キー | keyCode |
|------|---------|
| S | 1 |
| D | 2 |
| F | 3 |
| H | 4 |
| E | 14 |
| J | 38 |
| K | 40 |
| L | 37 |
| N | 45 |
| M | 46 |
| `[` | 33 |
| `;` | 41 |

修飾キーは `CGEventFlags`（`.maskControl`, `.maskShift` 等）で判定。Left/Right の区別は `flagsChanged` イベントの keyCode（`kVK_RightShift` = 60, `kVK_Control` = 59 等）を追跡する。

---

## 5. 実装ステップ

1. **雛形**: CGEventTap を作成し、全 keyDown をログ出力するだけの最小版。権限まわりを通す。
2. **静的リマップ**: 矢印キー・ESC・Delete を実装（2-2, 2-3）。
3. **修飾キー透過**: optional `any` 相当（Shift 等を出力イベントに引き継ぐ）を実装。
4. **マウスモード基盤**: Right Shift の押下追跡、MouseEngine とタイマーを実装。
5. **カーソル移動**: ESDF での連続移動（2-4 移動）。
6. **速度調整**: N/M の倍率（2-4 速度）。
7. **クリック**: JKL（2-4 クリック）。
8. **スクロール**: semicolon + ESDF（2-4 スクロール）。
9. **Caps Lock**: hidutil 連携 or 手順をドキュメント化（2-1）。
10. **常駐化**: LaunchAgent plist を用意して自動起動。

---

## 6. ビルドと実行

```sh
# ビルド
swiftc src/main.swift -o remap

# 実行（初回はアクセシビリティ権限の付与が必要）
./remap
```

権限: システム設定 → プライバシーとセキュリティ → アクセシビリティ に
実行バイナリ（またはターミナル）を追加。

---

## 7. 決定事項

- **Caps Lock リマップ**: hidutil をアプリが起動時に自動実行、終了時に解除。
- **アーミング挙動**: 簡略化。「Right Shift 押下中＝マウス操作有効」とする。
- **常駐方式**: メニューバーアプリ（Dock アイコンなし / `NSApplication` の `.accessory` ポリシー）。メニューに ON/OFF トグルと Quit。

### 残る微調整（実装後に体感で詰める）
- **マウス移動の速度感**: Karabiner の 1536 を px/s として採用。体感に合わせて定数を調整可能にする。
- **スクロール速度**: 同様に定数化して調整。
```
