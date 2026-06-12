// remap — macOS キーリマッパー
//
// 設計の骨組み。詳細(リマップ表の全項目, クリック/スクロールの細部)は
// コメントで省略してある。コアな配線・状態機械・タイマーのみ実コードで確定。
// 全体像は PLAN.md を参照。
//
// ビルド: swiftc src/main.swift -o remap && ./remap

import Cocoa
import CoreGraphics
import ApplicationServices

// =====================================================================
// MARK: - キーコード定数 (ANSI, kVK_ANSI_*)
// =====================================================================
// 必要な分だけ。完全な対応表は PLAN.md セクション4。
enum Key {
    static let s: Int64 = 1
    static let d: Int64 = 2
    static let f: Int64 = 3
    static let h: Int64 = 4
    static let e: Int64 = 14
    static let l: Int64 = 37
    static let j: Int64 = 38
    static let k: Int64 = 40
    static let semicolon: Int64 = 41
    static let n: Int64 = 45
    static let m: Int64 = 46
    static let leftBracket: Int64 = 33

    // 出力側
    static let escape: Int64 = 53
    static let delete: Int64 = 51 // backspace (delete_or_backspace)
    static let up: Int64 = 126
    static let down: Int64 = 125
    static let left: Int64 = 123
    static let right: Int64 = 124

    // flagsChanged で Left/Right を区別するための修飾キー keyCode
    static let rightShift: Int64 = 60
}

enum Direction { case up, down, left, right }

// デバッグログのオンオフ。true にすると各キーイベントと remap 発火を NSLog に出す。
// 不具合調査時のみ true にする（キーコードがログに残るため、通常は false）。
let remapDebug = false

// =====================================================================
// MARK: - MouseEngine
// =====================================================================
// マウス操作の実行系。押下中の連続移動はイベント駆動では表現できないので、
// 押されている方向の集合を保持し ~60Hz のタイマーで毎フレーム座標を更新する。
final class MouseEngine {

    // --- 調整用定数 (PLAN.md セクション7: 実装後に体感で詰める) ---
    private let baseSpeed: Double = 1536.0   // px/秒 (Karabiner の値)
    private let scrollSpeed: Double = 32.0    // ホイール量/フレーム相当
    private let tickHz: Double = 60.0

    // --- 状態 ---
    private var activeMoveKeys: Set<Direction> = []
    private var scrollMode = false           // semicolon 押下中
    private var speedMultiplier: Double = 1.0 // N=2.0 / M=0.3 / 既定1.0

    private var timer: DispatchSourceTimer?
    private var cursor: CGPoint = .zero       // 自前で追跡する論理カーソル位置

    // -- タイマー制御 --------------------------------------------------
    // 方向キーが1つでも押されている間だけタイマーを回す(アイドル時は止める)。
    private func ensureTimerRunning() {
        guard timer == nil, !activeMoveKeys.isEmpty else { return }
        cursor = CGEvent(source: nil)?.location ?? .zero
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / tickHz)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func stopTimerIfIdle() {
        guard activeMoveKeys.isEmpty else { return }
        timer?.cancel()
        timer = nil
    }

    // -- 毎フレーム処理 ------------------------------------------------
    private func tick() {
        guard !activeMoveKeys.isEmpty else { stopTimerIfIdle(); return }
        let perTick = baseSpeed * speedMultiplier / tickHz
        var dx = 0.0, dy = 0.0
        if activeMoveKeys.contains(.left)  { dx -= perTick }
        if activeMoveKeys.contains(.right) { dx += perTick }
        if activeMoveKeys.contains(.up)    { dy -= perTick }
        if activeMoveKeys.contains(.down)  { dy += perTick }

        if scrollMode {
            // スクロールモード: 方向を CGScrollWheelEvent に変換して post。
            //
            // macOS のホイールイベントの符号:
            //   wheel1 (縦軸): 正 = 上スクロール、負 = 下スクロール
            //   wheel2 (横軸): 正 = 左スクロール、負 = 右スクロール
            //
            // N(×2.0)/M(×0.3) の speedMultiplier をスクロール量にも反映させるため、
            // dx/dy 経由の正規化をやめ activeMoveKeys と speedMultiplier から直接算出する。
            //   amount = scrollSpeed × speedMultiplier (1フレーム分のホイール量)
            //   up    → wheel1 += +amount (正 = 上スクロール)
            //   down  → wheel1 += -amount
            //   left  → wheel2 += +amount (正 = 左スクロール)
            //   right → wheel2 += -amount
            //
            // units: .pixel を採用。.line より細かく連続的に動くため体感が滑らか。
            let amount = Int32((scrollSpeed * speedMultiplier).rounded())
            var wheel1: Int32 = 0  // 縦軸
            var wheel2: Int32 = 0  // 横軸
            if activeMoveKeys.contains(.up)    { wheel1 += +amount }  // 上スクロール
            if activeMoveKeys.contains(.down)  { wheel1 += -amount }  // 下スクロール
            if activeMoveKeys.contains(.left)  { wheel2 += +amount }  // 左スクロール
            if activeMoveKeys.contains(.right) { wheel2 += -amount }  // 右スクロール
            let scroll = CGEvent(scrollWheelEvent2Source: nil,
                                 units: .pixel,
                                 wheelCount: 2,
                                 wheel1: wheel1,
                                 wheel2: wheel2,
                                 wheel3: 0)
            scroll?.post(tap: .cghidEventTap)
        } else {
            // 物理マウスを動かしても内部 cursor が古い位置のままになるのを防ぐため、
            // dx/dy 加算の前に実際の現在位置で cursor を同期する。
            cursor = CGEvent(source: nil)?.location ?? cursor
            let target = CGPoint(x: cursor.x + dx, y: cursor.y + dy)
            // スクリーン境界クランプ: 全アクティブディスプレイの範囲内に収める。
            // メイン画面だけにクランプすると複数ディスプレイの境界を越えられないため、
            // どれかのディスプレイ内なら越境を許可する。
            cursor = MouseEngine.clampToDisplays(target: target, from: cursor)
            let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: cursor, mouseButton: .left)
            move?.post(tap: .cghidEventTap)
        }
    }

    // 全アクティブディスプレイの矩形を返す（グローバル座標, Retina スケール非依存）。
    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private static func contains(_ rects: [CGRect], _ p: CGPoint) -> Bool {
        // CGDisplayBounds は上端含む/下端含まずの半開区間。隣接ディスプレイが
        // 連続するよう maxX/maxY を排他に扱う。
        for r in rects where p.x >= r.minX && p.x < r.maxX && p.y >= r.minY && p.y < r.maxY {
            return true
        }
        return false
    }

    // target がいずれかのディスプレイ内ならそのまま、そうでなければ軸ごとに
    // 分けて越境可能な成分だけ採用する（斜め移動でディスプレイ間の隙間に
    // 入り込むのを防ぐ）。どの軸も無効なら現在位置に留める。
    private static func clampToDisplays(target: CGPoint, from current: CGPoint) -> CGPoint {
        let rects = activeDisplayBounds()
        if rects.isEmpty { return target }
        if contains(rects, target) { return target }
        let slideX = CGPoint(x: target.x, y: current.y)
        if contains(rects, slideX) { return slideX }
        let slideY = CGPoint(x: current.x, y: target.y)
        if contains(rects, slideY) { return slideY }
        return current
    }

    // -- 外部API (EventHandler から呼ばれる) ---------------------------
    func setMove(_ dir: Direction, pressed: Bool) {
        if pressed { activeMoveKeys.insert(dir) } else { activeMoveKeys.remove(dir) }
        if pressed { ensureTimerRunning() } else { stopTimerIfIdle() }
    }

    func setScrollMode(_ on: Bool) { scrollMode = on }

    func setSpeedMultiplier(_ m: Double) { speedMultiplier = m }

    func click(_ button: CGMouseButton) {
        // 実際の現在位置を取得（タイマー未起動時は cursor が .zero の可能性があるため）。
        let pos = CGEvent(source: nil)?.location ?? cursor

        // ボタン種別に応じた mouseDown/mouseUp のイベントタイプを決定。
        let downType: CGEventType
        let upType: CGEventType
        switch button {
        case .left:
            downType = .leftMouseDown
            upType   = .leftMouseUp
        case .right:
            downType = .rightMouseDown
            upType   = .rightMouseUp
        default: // .center (otherMouse)
            downType = .otherMouseDown
            upType   = .otherMouseUp
        }

        // mouseDown → mouseUp のペアを生成して送出。
        let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                           mouseCursorPosition: pos, mouseButton: button)
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                         mouseCursorPosition: pos, mouseButton: button)
        up?.post(tap: .cghidEventTap)
    }

    // モード解除時(Right Shift を離した時)に全状態をリセットする。
    func reset() {
        activeMoveKeys.removeAll()
        scrollMode = false
        speedMultiplier = 1.0
        stopTimerIfIdle()
    }
}

// =====================================================================
// MARK: - RemapController
// =====================================================================
// CGEventTap を所有し、コールバックから渡るイベントを捌く中枢。
final class RemapController {

    let mouse = MouseEngine()
    var enabled = true          // メニューバーの ON/OFF トグル

    private var mouseMode = false  // Right Shift 物理押下中か
    private var tap: CFMachPort?

    // 静的リマップで現在押下中のキー追跡辞書。
    // keyUp 時に Control が既に離されていても正しい keyUp を送出するために使う。
    // キー: 元の keyCode、値: 出力した keyCode。
    private var remappedDown: [Int64: Int64] = [:]

    // -- タップ生成 ----------------------------------------------------
    func start() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        // self を refcon 経由で C コールバックへ渡す。
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            // クラッシュさせず、原因が分かるようにログを残す。
            // ほぼ確実にアクセシビリティ権限の未付与 or 付与後に未再起動が原因。
            NSLog("[remap] CGEventTap の作成に失敗。アクセシビリティ権限を確認し、アプリを再起動してください。")
            return
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[remap] イベントタップを作成・有効化しました。リマップ稼働中。")
    }

    func reEnable() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    // -- イベント処理の中枢 -------------------------------------------
    // 戻り値: そのまま通す/差し替え -> event を返す。消費 -> nil。
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // タップが無効化されたら再有効化(タイムアウト対策)。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reEnable()
            return Unmanaged.passUnretained(event)
        }
        if !enabled { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if remapDebug {
            NSLog("[remap][ev] type=\(type.rawValue) keyCode=\(keyCode) ctrl=\(flags.contains(.maskControl)) shift=\(flags.contains(.maskShift)) mouseMode=\(mouseMode)")
        }

        // (1) flagsChanged: Right Shift を追跡してマウスモードを切替。
        if type == .flagsChanged {
            if keyCode == Key.rightShift {
                // NX_DEVICERSHIFTKEYMASK (0x4) で Right Shift 単独を判定する。
                // .maskShift は Left/Right 両方で立つため、Left Shift 併用時に
                // Right Shift を離しても解除されない問題を回避する。
                let pressed = (event.flags.rawValue & 0x4) != 0
                if pressed {
                    mouseMode = true
                } else {
                    mouseMode = false
                    mouse.reset()
                }
                // Right Shift はシステムに透過させない。透過するとマウスモード中の
                // クリック等が Shift+クリック扱いになるため、純粋なモードキーとして消費する。
                return nil
            }
            // Right Shift 以外の修飾キー (Left Control 等) は従来通り透過する。
            return Unmanaged.passUnretained(event)
        }

        let isDown = (type == .keyDown)

        // (2) マウスモード中: ESDF/JKL/NM/; を消費して MouseEngine へ。
        if mouseMode, let consumed = routeMouse(keyCode: keyCode, isDown: isDown) {
            return consumed ? nil : Unmanaged.passUnretained(event)
        }

        // (3) 静的リマップ: Left Control + キー -> 矢印/ESC/Backspace。
        //     optional `any` = control 以外の修飾(Shift等)は出力に引き継ぐ。
        //     keyDown/keyUp の両方を差し替える(OS に対の down/up を見せるため)。
        //
        //     keyUp 時は remappedDown を優先して引く。Control を先に離した場合でも
        //     押下時に記録した出力 keyCode を使い、down/up のペアを保証する。
        if isDown {
            // keyDown(1): 既にリマップ中のキーのオートリピート。
            // 一度リマップしたキーは、トリガ修飾(Control)や他修飾を途中で離しても、
            // 物理的に離される(keyUp)まで同じ出力キーを送り続ける。
            // これにより「押下中に修飾を先に離すと素の文字が入力される」問題を防ぐ。
            if let existing = remappedDown[keyCode] {
                event.setIntegerValueField(.keyboardEventKeycode, value: existing)
                var f = flags
                f.remove(.maskControl)
                event.flags = f
                return Unmanaged.passUnretained(event)
            }
            // keyDown(2): 新規。Control 押下中かつリマップ対象なら辞書に記録して差し替える。
            if flags.contains(.maskControl), let newKey = staticRemap(keyCode: keyCode) {
                if remapDebug { NSLog("[remap][remap] keyCode \(keyCode) -> \(newKey) を発火") }
                remappedDown[keyCode] = newKey          // 元keyCode -> 出力keyCode を記録
                event.setIntegerValueField(.keyboardEventKeycode, value: newKey)
                var f = flags
                f.remove(.maskControl)                  // control を取り除き
                event.flags = f                         // 他修飾(Shift等)はそのまま透過
                return Unmanaged.passUnretained(event)
            }
        } else {
            // keyUp: 修飾キーの現在状態に関係なく辞書を先に確認する。
            // Control を先に離した場合でも正しい keyUp を送出して「押しっぱなし」を防ぐ。
            if let newKey = remappedDown.removeValue(forKey: keyCode) {
                event.setIntegerValueField(.keyboardEventKeycode, value: newKey)
                var f = flags
                f.remove(.maskControl)                  // 念のため control を除去
                event.flags = f
                return Unmanaged.passUnretained(event)
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // -- 静的リマップ表 (2-2, 2-3) -------------------------------------
    // Left Control 前提。該当しなければ nil。
    private func staticRemap(keyCode: Int64) -> Int64? {
        switch keyCode {
        case Key.e: return Key.up
        case Key.d: return Key.down
        case Key.s: return Key.left
        case Key.f: return Key.right
        case Key.leftBracket: return Key.escape
        case Key.h: return Key.delete
        default: return nil
        }
    }

    // -- マウス入力ルーティング (2-4) ----------------------------------
    // 戻り値: nil=対象外(マウスモードでも素通し), true=消費, false=素通し。
    private func routeMouse(keyCode: Int64, isDown: Bool) -> Bool? {
        switch keyCode {
        case Key.e: mouse.setMove(.up, pressed: isDown); return true
        case Key.d: mouse.setMove(.down, pressed: isDown); return true
        case Key.s: mouse.setMove(.left, pressed: isDown); return true
        case Key.f: mouse.setMove(.right, pressed: isDown); return true
        case Key.semicolon: mouse.setScrollMode(isDown); return true
        case Key.n: mouse.setSpeedMultiplier(isDown ? 2.0 : 1.0); return true
        case Key.m: mouse.setSpeedMultiplier(isDown ? 0.3 : 1.0); return true
        case Key.j: if isDown { mouse.click(.left) };   return true
        case Key.k: if isDown { mouse.click(.center) }; return true
        case Key.l: if isDown { mouse.click(.right) };  return true
        default: return nil
        }
    }
}

// C コールバック (グローバル関数)。refcon から RemapController を復元して委譲。
private func eventTapCallback(proxy: CGEventTapProxy,
                             type: CGEventType,
                             event: CGEvent,
                             refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<RemapController>.fromOpaque(refcon).takeUnretainedValue()
    return controller.handle(type: type, event: event)
}

// =====================================================================
// MARK: - Caps Lock リマップ (2-1) hidutil 連携
// =====================================================================
enum CapsLockRemap {
    // Caps Lock(0x700000039) -> Left Control(0x7000000E0)。HID usage (Usage Page 0x07)。
    static func apply() {
        // hidutil を使って Caps Lock を Left Control にリマップする。
        // HID usage: Caps Lock = 0x700000039, Left Control = 0x7000000E0
        let mapping = #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x7000000E0}]}"#
        runHidutil(argument: mapping)
    }

    static func revert() {
        // UserKeyMapping を空配列に設定してリマップを解除する。
        let mapping = #"{"UserKeyMapping":[]}"#
        runHidutil(argument: mapping)
    }

    // hidutil property --set <argument> を実行するヘルパー。
    private static func runHidutil(argument: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", argument]
        try? process.run()
        process.waitUntilExit()
    }
}

// =====================================================================
// MARK: - アプリ本体 (メニューバー常駐, .accessory)
// =====================================================================
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = RemapController()
    private var statusItem: NSStatusItem!
    // トグル項目を保持しておき、クリック後にタイトル/状態を更新するために参照する。
    private var toggleItem: NSMenuItem!
    // SIGINT / SIGTERM を捕捉するシグナルソース。解放されないよう保持する。
    private var signalSources: [DispatchSourceSignal] = []
    // アクセシビリティ権限の付与を待つポーリングタイマー。
    private var axPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[remap] 起動。Caps Lock リマップを適用します。")
        CapsLockRemap.apply()

        // アクセシビリティ権限を確認し、未許可の場合はシステムのダイアログを促す。
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        NSLog("[remap] アクセシビリティ権限 trusted = \(trusted)")
        if trusted {
            controller.start()
        } else {
            // 権限が無い場合は、付与を検知して「再起動なしで」タップを開始するため
            // ポーリングする。再ビルドで署名が変わるたびに権限が外れるが、
            // これにより付与した瞬間に有効化される（アプリの再起動・open し直し不要）。
            NSLog("[remap] 権限が未付与です。システム設定 > プライバシーとセキュリティ > アクセシビリティ で remap を許可してください（付与後、自動で有効化されます）。")
            axPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                if AXIsProcessTrusted() {
                    NSLog("[remap] 権限を検知。タップを開始します。")
                    self.controller.start()
                    t.invalidate()
                    self.axPollTimer = nil
                }
            }
        }

        // SIGINT / SIGTERM を DispatchSource で捕捉し、Caps Lock を復元してから終了する。
        // signal() で SIG_IGN に設定してから DispatchSource を登録する (二重発火防止)。
        signal(SIGINT,  SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        for sig in [SIGINT, SIGTERM] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                CapsLockRemap.revert()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }

        setupMenuBar()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CapsLockRemap.revert()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // ボタンのアイコン設定。SF Symbol が利用できる環境では "keyboard" を使い、
        // できない場合は絵文字テキストにフォールバックして堅牢性を保つ。
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "remap") {
                image.isTemplate = true // ダークモード/ライトモード両対応
                button.image = image
            } else {
                button.title = "⌨"
            }
        }

        // メニュー構築
        let menu = NSMenu()

        // (1) ON/OFF トグル項目
        toggleItem = NSMenuItem(
            title: toggleTitle(),
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.state = controller.enabled ? .on : .off
        menu.addItem(toggleItem)

        // (2) セパレータ
        menu.addItem(.separator())

        // (3) Quit 項目
        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        NSLog("[remap] メニューバー項目を設置しました (button=\(statusItem.button != nil), visible=\(statusItem.isVisible)).")
    }

    // enabled の状態に応じたメニュー項目タイトルを返す。
    private func toggleTitle() -> String {
        return controller.enabled ? "ON (クリックで OFF)" : "OFF (クリックで ON)"
    }

    // ON/OFF トグルアクション
    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        controller.enabled.toggle()
        // チェックマーク状態とタイトルを現在の enabled に同期する。
        toggleItem.state = controller.enabled ? .on : .off
        toggleItem.title = toggleTitle()
    }

    // アプリ終了アクション (applicationWillTerminate で CapsLockRemap.revert が呼ばれる)
    @objc private func quit(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }
}

// -- エントリポイント --------------------------------------------------
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Dock アイコンなしのメニューバー常駐
let delegate = AppDelegate()
app.delegate = delegate
app.run()
