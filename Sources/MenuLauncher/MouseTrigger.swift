import AppKit

/// 配置里的一条鼠标触发：按下某个鼠标键（可带修饰键）时呼出面板
struct MouseBinding: Codable, Equatable {
    /// "back" / "forward" / "middle"，或鼠标键编号（0 左键、1 右键、2 中键、3 后退侧键、4 前进侧键，更多键依次往后）
    var button: ButtonRef
    /// "command" / "option" / "control" / "shift"，必须完全一致；省略表示不按修饰键
    var modifiers: [String] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        button = try c.decode(ButtonRef.self, forKey: .button)
        modifiers = try c.decodeIfPresent([String].self, forKey: .modifiers) ?? []
    }

    var flags: CGEventFlags? {
        var f: CGEventFlags = []
        for m in modifiers {
            switch m.lowercased() {
            case "command", "cmd": f.insert(.maskCommand)
            case "option", "alt", "opt": f.insert(.maskAlternate)
            case "control", "ctrl": f.insert(.maskControl)
            case "shift": f.insert(.maskShift)
            default: return nil
            }
        }
        return f
    }
}

struct ButtonRef: Codable, Equatable {
    let number: Int?
    let raw: String

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) {
            number = n; raw = String(n)
        } else {
            raw = try c.decode(String.self)
            switch raw.lowercased() {
            case "middle": number = 2
            case "back": number = 3
            case "forward": number = 4
            default: number = Int(raw)
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

/// 全局监听鼠标键。用 CGEventTap 而不是 NSEvent 全局监听：匹配到的点击要吞掉，
/// 否则侧键在浏览器里还会触发后退。事件拦截需要「辅助功能」权限
@MainActor
final class MouseTrigger {
    var bindings: [(button: Int, flags: CGEventFlags)] = [] {
        didSet { bindings.isEmpty ? stop() : start() }
    }
    private let handler: () -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?
    private var prompted = false
    /// 按下时吞掉的键，松开事件也要一起吞掉
    private var swallowing = Set<Int>()

    private static let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    init(handler: @escaping () -> Void) { self.handler = handler }

    private func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, ctx in
            let me = Unmanaged<MouseTrigger>.fromOpaque(ctx!).takeUnretainedValue()
            return MainActor.assumeIsolated { me.handle(type, event) }
        }, userInfo: me) else {
            // 没有辅助功能权限：弹一次系统授权提示，之后每隔几秒重试，授权后自动生效
            if !prompted {
                prompted = true
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
            if retry == nil {
                retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.start() }
                }
            }
            return
        }
        retry?.invalidate()
        retry = nil
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        retry?.invalidate()
        retry = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 系统觉得回调太慢会把 tap 关掉，重新打开
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        default: break
        }
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let flags = event.flags.intersection(Self.relevant)
        switch type {
        case .otherMouseDown, .leftMouseDown, .rightMouseDown:
            guard bindings.contains(where: { $0.button == button && $0.flags == flags }) else { break }
            swallowing.insert(button)
            handler()
            return nil
        case .otherMouseUp, .leftMouseUp, .rightMouseUp:
            if swallowing.remove(button) != nil { return nil }
        default: break
        }
        return Unmanaged.passUnretained(event)
    }
}
