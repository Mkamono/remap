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

enum Direction { case up, down, left, right }

// デバッグログのオンオフ。true にすると各キーイベントと remap 発火を NSLog に出す。
// 不具合調査時のみ true にする（キーコードがログに残るため、通常は false）。
let remapDebug = false

// =====================================================================
// MARK: - キー名テーブル (設定ファイルの文字列 ↔ 仮想キーコード)
// =====================================================================
// 設定ファイルではキーを "e" / "semicolon" / "right_shift" のような名前で書く。
// それを内部の仮想キーコード(kVK_*)へ変換する対応表。
enum KeyNames {
    static let table: [String: Int64] = [
        // 英字・数字・記号 (kVK_ANSI_*)
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
        "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "equal": 24, "9": 25, "7": 26, "minus": 27, "8": 28, "0": 29,
        "right_bracket": 30, "o": 31, "u": 32, "left_bracket": 33, "i": 34,
        "p": 35, "return": 36, "l": 37, "j": 38, "quote": 39, "k": 40,
        "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "n": 45,
        "m": 46, "period": 47, "tab": 48, "space": 49, "grave": 50,
        // 特殊キー
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forward_delete": 117, "up": 126, "down": 125, "left": 123, "right": 124,
        "home": 115, "end": 119, "page_up": 116, "page_down": 121,
        // 修飾キー (モードキー用)
        "command": 55, "left_command": 55, "right_command": 54,
        "shift": 56, "left_shift": 56, "right_shift": 60, "caps_lock": 57,
        "option": 58, "left_option": 58, "right_option": 61,
        "control": 59, "left_control": 59, "right_control": 62, "function": 63,
    ]

    // 修飾キーの flagsChanged で「押された」を判定するためのデバイス依存ビット
    // (NX_DEVICE*KEYMASK)。左右を区別できるよう keyCode 単位で持つ。
    static let deviceBit: [Int64: UInt64] = [
        59: 0x1, 56: 0x2, 60: 0x4, 55: 0x8, 54: 0x10, 58: 0x20, 61: 0x40, 62: 0x2000,
    ]

    // 静的リマップのトリガ修飾名 → CGEventFlags マスク。
    static let modifierMask: [String: CGEventFlags] = [
        "control": .maskControl, "shift": .maskShift,
        "option": .maskAlternate, "command": .maskCommand,
    ]

    static func code(_ name: String) -> Int64? { table[name.lowercased()] }
}

// マウスモードで物理キーに割り当てられる動作。
enum MouseAction {
    case move(Direction)
    case scroll
    case fast
    case slow
    case button(CGMouseButton)
}

// =====================================================================
// MARK: - 設定 (config.json から読む。無ければ下記デフォルト)
// =====================================================================
// マウスエンジンの数値チューニング。
struct MouseTuning {
    var baseSpeed: Double = 1536.0
    var scrollSpeed: Double = 32.0
    var tickHz: Double = 60.0
    var slowMinMultiplier: Double = 0.04
    var slowMaxMultiplier: Double = 1.0
    var slowRampSeconds: Double = 1.5
    var fastMultiplier: Double = 2.0
}

struct Config {
    var tuning = MouseTuning()
    var modeKeyCode: Int64 = 60                  // right_shift
    var mouseBindings: [Int64: MouseAction] = Config.defaultMouseBindings
    var remapModifier: CGEventFlags = .maskControl
    var remapTable: [Int64: Int64] = Config.defaultRemapTable
    var capsToControl = true

    // 既定のマウスモード割り当て (keyCode → 動作)。
    static let defaultMouseBindings: [Int64: MouseAction] = [
        14: .move(.up), 2: .move(.down), 1: .move(.left), 3: .move(.right),
        41: .scroll, 45: .fast, 46: .slow,
        38: .button(.left), 40: .button(.center), 37: .button(.right),
    ]
    // 既定の静的リマップ (入力keyCode → 出力keyCode)。Ctrl 前提。
    static let defaultRemapTable: [Int64: Int64] = [
        14: 126, 2: 125, 1: 123, 3: 124, 33: 53, 4: 51,
    ]

    // 動作名 → MouseAction (mouseMode セクションのフィールド名に対応)。
    private static let mouseFieldAction: [String: MouseAction] = [
        "moveUp": .move(.up), "moveDown": .move(.down),
        "moveLeft": .move(.left), "moveRight": .move(.right),
        "scroll": .scroll, "fast": .fast, "slow": .slow,
        "leftClick": .button(.left), "middleClick": .button(.center),
        "rightClick": .button(.right),
    ]
    // mouseMode の既定キー名 (省略時に使う)。
    private static let mouseFieldDefaultName: [String: String] = [
        "moveUp": "e", "moveDown": "d", "moveLeft": "s", "moveRight": "f",
        "scroll": "semicolon", "fast": "n", "slow": "m",
        "leftClick": "j", "middleClick": "k", "rightClick": "l",
    ]

    // JSON データから設定を組み立てる。欠落・不正なフィールドはデフォルトのまま。
    static func load(from data: Data) -> Config {
        var cfg = Config()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            NSLog("[remap] config.json をパースできませんでした。デフォルト設定で動作します。")
            return cfg
        }

        // mouse: 数値チューニング
        if let m = root["mouse"] as? [String: Any] {
            func n(_ k: String) -> Double? { (m[k] as? NSNumber)?.doubleValue }
            if let v = n("baseSpeed")          { cfg.tuning.baseSpeed = v }
            if let v = n("scrollSpeed")        { cfg.tuning.scrollSpeed = v }
            if let v = n("tickHz"), v > 0      { cfg.tuning.tickHz = v }
            if let v = n("slowMinMultiplier")  { cfg.tuning.slowMinMultiplier = v }
            if let v = n("slowMaxMultiplier")  { cfg.tuning.slowMaxMultiplier = v }
            if let v = n("slowRampSeconds"), v > 0 { cfg.tuning.slowRampSeconds = v }
            if let v = n("fastMultiplier")     { cfg.tuning.fastMultiplier = v }
        }

        // mouseMode: モードキーと各動作のキー割り当て
        var names = mouseFieldDefaultName
        if let mm = root["mouseMode"] as? [String: Any] {
            if let s = mm["modeKey"] as? String, let kc = KeyNames.code(s) {
                cfg.modeKeyCode = kc
            }
            for field in Array(names.keys) {
                if let s = mm[field] as? String { names[field] = s }
            }
        }
        var binds: [Int64: MouseAction] = [:]
        for (field, name) in names {
            if let kc = KeyNames.code(name), let action = mouseFieldAction[field] {
                binds[kc] = action
            }
        }
        if !binds.isEmpty { cfg.mouseBindings = binds }

        // remap: トリガ修飾と入力→出力の対応
        if let rm = root["remap"] as? [String: Any] {
            if let mod = rm["modifier"] as? String,
               let mask = KeyNames.modifierMask[mod.lowercased()] {
                cfg.remapModifier = mask
            }
            if let b = rm["bindings"] as? [String: Any] {
                var table: [Int64: Int64] = [:]
                for (inName, out) in b {
                    if let inCode = KeyNames.code(inName),
                       let outName = out as? String,
                       let outCode = KeyNames.code(outName) {
                        table[inCode] = outCode
                    }
                }
                if !table.isEmpty { cfg.remapTable = table }
            }
        }

        // capsLock: Caps Lock を Left Control にするか
        if let cl = root["capsLock"] as? [String: Any],
           let b = cl["remapToControl"] as? Bool {
            cfg.capsToControl = b
        }

        return cfg
    }

    // 初回生成用のデフォルト設定ファイル本文 (上のデフォルト値と一致)。
    static let defaultFileContents = """
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

    """
}

// =====================================================================
// MARK: - 設定ファイルの場所・読み込み・監視
// =====================================================================
enum ConfigStore {
    // ~/.config/remap/config.json
    static var fileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/remap/config.json")
    }

    // 設定を読む。ファイルが無ければデフォルトを書き出して生成する。
    static func loadOrCreate() -> Config {
        let url = fileURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try Config.defaultFileContents.write(to: url, atomically: true, encoding: .utf8)
                NSLog("[remap] 既定の設定ファイルを作成しました: \(url.path)")
            } catch {
                NSLog("[remap] 設定ファイルを作成できませんでした (\(error))。デフォルト設定で動作します。")
                return Config()
            }
        }
        guard let data = try? Data(contentsOf: url) else {
            NSLog("[remap] 設定ファイルを読めませんでした。デフォルト設定で動作します。")
            return Config()
        }
        return Config.load(from: data)
    }
}

// config.json を含むディレクトリを監視し、変更時に再読込する。
// ディレクトリを見張るのでエディタの「保存=置き換え」(atomic save)でも取りこぼさない。
final class ConfigWatcher {
    private let dirURL: URL
    private let onChange: () -> Void
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var pending = false

    init(onChange: @escaping () -> Void) {
        self.dirURL = ConfigStore.fileURL.deletingLastPathComponent()
        self.onChange = onChange
    }

    func start() {
        fd = open(dirURL.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[remap] 設定ディレクトリの監視を開始できません: \(dirURL.path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: .main)
        src.setEventHandler { [weak self] in self?.coalesce() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
        }
        source = src
        src.resume()
        NSLog("[remap] 設定ファイルの監視を開始しました: \(ConfigStore.fileURL.path)")
    }

    // 保存方式によって短時間に複数イベントが来るので、少し待ってまとめて反映する。
    private func coalesce() {
        if pending { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pending = false
            self?.onChange()
        }
    }
}

// =====================================================================
// MARK: - MouseEngine
// =====================================================================
// マウス操作の実行系。押下中の連続移動はイベント駆動では表現できないので、
// 押されている方向の集合を保持し ~60Hz のタイマーで毎フレーム座標を更新する。
final class MouseEngine {

    // --- 調整用パラメータ ---
    // 既定値は MouseTuning の初期値。config.json があれば起動時/保存時に差し替わる。
    // (baseSpeed=px/秒, scrollSpeed=ホイール量/フレーム相当, tickHz=更新頻度,
    //  slowMin/Max/RampSeconds=低速モードのランプ, fastMultiplier=高速倍率)
    var tuning = MouseTuning()

    // --- 状態 ---
    private var activeMoveKeys: Set<Direction> = []
    private var scrollMode = false           // semicolon 押下中
    private var fastActive = false           // N 押下中: 高速(×2.0)
    private var slowActive = false           // M 押下中: 低速(動かし続けると加速)
    private var slowStartTime = DispatchTime.now() // 低速移動エピソードの起点
    private var heldButtons: Set<UInt32> = []      // 押し下げ保持中のボタン(ドラッグ用)

    private var timer: DispatchSourceTimer?
    private var cursor: CGPoint = .zero       // 自前で追跡する論理カーソル位置

    // -- タイマー制御 --------------------------------------------------
    // 方向キーが1つでも押されている間だけタイマーを回す(アイドル時は止める)。
    private func ensureTimerRunning() {
        guard timer == nil, !activeMoveKeys.isEmpty else { return }
        // 静止状態から移動を開始した瞬間を低速ランプの起点にする。
        // これで M 押しっぱなしでも、方向キーを押し始めた直後は最も遅くなる。
        slowStartTime = DispatchTime.now()
        cursor = CGEvent(source: nil)?.location ?? .zero
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / tuning.tickHz)
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
        let multiplier = currentMultiplier()
        let perTick = tuning.baseSpeed * multiplier / tuning.tickHz
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
            let amount = Int32((tuning.scrollSpeed * multiplier).rounded())
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
            // ボタン保持中はドラッグイベント、そうでなければ通常移動。
            let (moveType, btn) = moveEvent()
            let move = CGEvent(mouseEventSource: nil, mouseType: moveType,
                               mouseCursorPosition: cursor, mouseButton: btn)
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

    // 走査線 y 上で、x を有効範囲にクランプした座標を返す（y を含むディスプレイが
    // 無ければ nil）。x がいずれかのディスプレイの X 区間内ならそのまま、外なら
    // 最寄りの端へ寄せる。隣接ディスプレイがあれば自然と越境でき、無ければ画面の
    // きわ(端)まで到達できる。
    private static func clampX(_ x: CGFloat, atY y: CGFloat, _ rects: [CGRect]) -> CGFloat? {
        let spans = rects.filter { y >= $0.minY && y < $0.maxY }
        if spans.isEmpty { return nil }
        for s in spans where x >= s.minX && x < s.maxX { return x }
        let eps: CGFloat = 1   // 半開区間の右端(maxX)は含まないため 1px 内側が端
        var best: CGFloat?
        for s in spans {
            let c = Swift.min(Swift.max(x, s.minX), s.maxX - eps)
            if best == nil || abs(c - x) < abs(best! - x) { best = c }
        }
        return best
    }

    // clampX の Y 版。
    private static func clampY(_ y: CGFloat, atX x: CGFloat, _ rects: [CGRect]) -> CGFloat? {
        let spans = rects.filter { x >= $0.minX && x < $0.maxX }
        if spans.isEmpty { return nil }
        for s in spans where y >= s.minY && y < s.maxY { return y }
        let eps: CGFloat = 1
        var best: CGFloat?
        for s in spans {
            let c = Swift.min(Swift.max(y, s.minY), s.maxY - eps)
            if best == nil || abs(c - y) < abs(best! - y) { best = c }
        }
        return best
    }

    // target がいずれかのディスプレイ内ならそのまま。外なら軸ごとに端へクランプし、
    // 画面のきわまで到達できるようにする（隣接ディスプレイがあれば越境、無ければ
    // 端で止まる）。斜め移動でディスプレイ間の隙間に入り込むのも防ぐ。
    private static func clampToDisplays(target: CGPoint, from current: CGPoint) -> CGPoint {
        let rects = activeDisplayBounds()
        if rects.isEmpty { return target }
        if contains(rects, target) { return target }
        let x = clampX(target.x, atY: current.y, rects) ?? current.x
        let y = clampY(target.y, atX: x, rects) ?? current.y
        let p = CGPoint(x: x, y: y)
        if contains(rects, p) { return p }
        // 念のためのフォールバック（通常ここには来ない）。
        if contains(rects, CGPoint(x: x, y: current.y)) { return CGPoint(x: x, y: current.y) }
        if contains(rects, CGPoint(x: current.x, y: y)) { return CGPoint(x: current.x, y: y) }
        return current
    }

    // -- 外部API (EventHandler から呼ばれる) ---------------------------
    func setMove(_ dir: Direction, pressed: Bool) {
        if pressed { activeMoveKeys.insert(dir) } else { activeMoveKeys.remove(dir) }
        if pressed { ensureTimerRunning() } else { stopTimerIfIdle() }
    }

    func setScrollMode(_ on: Bool) { scrollMode = on }

    // N: 高速。押している間 ×2.0。
    func setFast(_ on: Bool) { fastActive = on }

    // M: 低速。ランプの起点は基本「移動開始時」(ensureTimerRunning) だが、
    // 移動中に M を押した場合はその瞬間から遅くしたいので、ここでも起点を更新する。
    // (連続キーリピートでは再開しないよう !slowActive で一度だけ)
    func setSlow(_ on: Bool) {
        if on && !slowActive { slowStartTime = DispatchTime.now() }
        slowActive = on
    }

    // 現フレームの速度倍率。低速(M)が最優先で、移動開始からの経過で min→max へランプ。
    private func currentMultiplier() -> Double {
        if slowActive {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds
                                 &- slowStartTime.uptimeNanoseconds) / 1_000_000_000
            let progress = min(max(elapsed / tuning.slowRampSeconds, 0), 1)
            return tuning.slowMinMultiplier
                + (tuning.slowMaxMultiplier - tuning.slowMinMultiplier) * progress
        }
        if fastActive { return tuning.fastMultiplier }
        return 1.0
    }

    // ボタンの押し下げ/解放。押している間は保持されるので、保持中に方向キーで
    // 動かすとドラッグになる（tick の移動ブランチが drag イベントを送る）。
    // チョン押し(down→すぐup)は通常のクリックとして振る舞う。
    func setButton(_ button: CGMouseButton, pressed: Bool) {
        if pressed {
            // 自動キーリピートによる二重 down を無視。
            guard heldButtons.insert(button.rawValue).inserted else { return }
            postButton(button, down: true)
        } else {
            guard heldButtons.remove(button.rawValue) != nil else { return }
            postButton(button, down: false)
        }
    }

    private func postButton(_ button: CGMouseButton, down: Bool) {
        // 実際の現在位置を取得（タイマー未起動時は cursor が .zero の可能性があるため）。
        let pos = CGEvent(source: nil)?.location ?? cursor
        let type: CGEventType
        switch button {
        case .left:  type = down ? .leftMouseDown  : .leftMouseUp
        case .right: type = down ? .rightMouseDown : .rightMouseUp
        default:     type = down ? .otherMouseDown : .otherMouseUp
        }
        let ev = CGEvent(mouseEventSource: nil, mouseType: type,
                         mouseCursorPosition: pos, mouseButton: button)
        ev?.post(tap: .cghidEventTap)
    }

    // 保持中ボタンに応じた移動イベント種別とボタンを返す。
    // 何も保持していなければ通常の mouseMoved。
    private func moveEvent() -> (CGEventType, CGMouseButton) {
        if heldButtons.contains(CGMouseButton.left.rawValue)   { return (.leftMouseDragged, .left) }
        if heldButtons.contains(CGMouseButton.right.rawValue)  { return (.rightMouseDragged, .right) }
        if heldButtons.contains(CGMouseButton.center.rawValue) { return (.otherMouseDragged, .center) }
        return (.mouseMoved, .left)
    }

    // モード解除時(Right Shift を離した時)に全状態をリセットする。
    func reset() {
        // 保持中のボタンは離して送出しておく(ドラッグ中に抜けてもボタンが
        // 押しっぱなしで固まらないように)。
        for raw in heldButtons {
            postButton(CGMouseButton(rawValue: raw) ?? .left, down: false)
        }
        heldButtons.removeAll()
        activeMoveKeys.removeAll()
        scrollMode = false
        fastActive = false
        slowActive = false
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
    var config = Config() {     // config.json 由来。再読込で差し替わる。
        didSet { mouse.tuning = config.tuning }
    }

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

        // (1) flagsChanged: モードキー(既定 Right Shift)を追跡してマウスモードを切替。
        if type == .flagsChanged {
            if keyCode == config.modeKeyCode {
                // デバイス依存ビット(NX_DEVICE*KEYMASK)で左右を区別して押下判定する。
                // .maskShift 等は Left/Right 両方で立つため、併用時に取りこぼす問題を避ける。
                // (右Shift なら 0x4。テーブルに無いキーは 0x4 にフォールバック)
                let bit = KeyNames.deviceBit[keyCode] ?? 0x4
                let pressed = (event.flags.rawValue & bit) != 0
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
                f.remove(config.remapModifier)
                event.flags = f
                return Unmanaged.passUnretained(event)
            }
            // keyDown(2): 新規。トリガ修飾(既定 Control)押下中かつリマップ対象なら
            // 辞書に記録して差し替える。
            if flags.contains(config.remapModifier), let newKey = staticRemap(keyCode: keyCode) {
                if remapDebug { NSLog("[remap][remap] keyCode \(keyCode) -> \(newKey) を発火") }
                remappedDown[keyCode] = newKey          // 元keyCode -> 出力keyCode を記録
                event.setIntegerValueField(.keyboardEventKeycode, value: newKey)
                var f = flags
                f.remove(config.remapModifier)          // トリガ修飾を取り除き
                event.flags = f                         // 他修飾(Shift等)はそのまま透過
                return Unmanaged.passUnretained(event)
            }
        } else {
            // keyUp: 修飾キーの現在状態に関係なく辞書を先に確認する。
            // Control を先に離した場合でも正しい keyUp を送出して「押しっぱなし」を防ぐ。
            if let newKey = remappedDown.removeValue(forKey: keyCode) {
                event.setIntegerValueField(.keyboardEventKeycode, value: newKey)
                var f = flags
                f.remove(config.remapModifier)          // 念のためトリガ修飾を除去
                event.flags = f
                return Unmanaged.passUnretained(event)
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // -- 静的リマップ表 -------------------------------------------------
    // トリガ修飾(既定 Control)前提。該当しなければ nil。config.json で定義。
    private func staticRemap(keyCode: Int64) -> Int64? {
        config.remapTable[keyCode]
    }

    // -- マウス入力ルーティング ----------------------------------------
    // 戻り値: nil=対象外(マウスモードでも素通し), true=消費, false=素通し。
    // 割り当ては config.mouseBindings (config.json) で定義。
    private func routeMouse(keyCode: Int64, isDown: Bool) -> Bool? {
        guard let action = config.mouseBindings[keyCode] else { return nil }
        switch action {
        case .move(let dir):  mouse.setMove(dir, pressed: isDown)
        case .scroll:         mouse.setScrollMode(isDown)
        case .fast:           mouse.setFast(isDown)
        case .slow:           mouse.setSlow(isDown)
        case .button(let b):  mouse.setButton(b, pressed: isDown)
        }
        return true
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
    // config.json の変更監視。解放されないよう保持する。
    private var configWatcher: ConfigWatcher?
    // 現在 Caps Lock → Control のリマップを適用済みか。
    private var capsApplied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[remap] 起動。設定を読み込みます。")
        // 設定を読み込んで適用 (Caps Lock のリマップ可否もここで決まる)。
        reloadConfig()
        // 設定ファイルの変更を監視し、保存されたら再ビルドなしで反映する。
        configWatcher = ConfigWatcher { [weak self] in self?.reloadConfig() }
        configWatcher?.start()

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

    // config.json を読み込み、コントローラと Caps Lock リマップに反映する。
    // 起動時と、設定ファイル保存の検知時の両方から呼ばれる。
    private func reloadConfig() {
        let cfg = ConfigStore.loadOrCreate()
        controller.config = cfg   // didSet で mouse.tuning も更新される
        // Caps Lock のリマップは現在の適用状態と差分があるときだけ切り替える。
        if cfg.capsToControl && !capsApplied {
            CapsLockRemap.apply()
            capsApplied = true
        } else if !cfg.capsToControl && capsApplied {
            CapsLockRemap.revert()
            capsApplied = false
        }
        NSLog("[remap] 設定を適用しました。")
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
