import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// 菜单样式的无边框面板：毛玻璃背景 + 圆角，不激活本应用也能接收键盘输入。
final class DropdownPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.searchHeight),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor

        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: DropdownPanel!
    private let model = LauncherModel()
    private var hotKey: HotKey?
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Launcher")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let hosting = NSHostingView(rootView: LauncherView(model: model))
        hosting.sizingOptions = []
        panel = DropdownPanel(content: hosting)
        panel.onResignKey = { [weak self] in self?.hide() }

        model.onLaunched = { [weak self] in self?.hide() }
        // objectWillChange 在属性改变前触发，放到下一轮 runloop 再读新高度
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.resize() }
            .store(in: &cancellables)
        model.loadConfig()
        model.reload()

        // ⌥Space 呼出
        hotKey = HotKey(keyCode: kVK_Space, modifiers: optionKey) { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggle()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "重新扫描应用", action: #selector(rescan), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "编辑配置文件…", action: #selector(editConfig), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func rescan() { model.reload() }

    @objc private func editConfig() { model.openConfig() }

    private func toggle() {
        panel.isVisible ? hide() : show()
    }

    private func show() {
        model.prepareForShow()
        resize()
        positionUnderStatusItem()
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        installKeyMonitor()
    }

    /// 面板常驻，关闭只是隐藏。重置和重扫都放在隐藏之后做，打开时不再有额外工作
    private func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        DispatchQueue.main.async { [model] in
            model.resetAfterHide()
            model.reloadIfStale()
        }
    }

    /// 面板顶部贴住菜单栏图标下沿，左对齐图标；超出屏幕右侧时往左收
    private func positionUnderStatusItem() {
        guard let button = statusItem.button, let window = button.window else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main!
        var x = buttonRect.minX
        x = min(x, screen.visibleFrame.maxX - panel.frame.width - 6)
        let topY = buttonRect.minY - 4
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: topY))
    }

    /// 保持顶边不动，按当前模式调整高度
    private func resize() {
        guard let panel else { return }
        let height = model.preferredHeight
        guard panel.frame.height != height else { return }
        let top = panel.frame.maxY
        var frame = panel.frame
        frame.size.height = height
        frame.origin.y = top - frame.size.height
        panel.setFrame(frame, display: true)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            switch Int(event.keyCode) {
            case kVK_DownArrow: self.model.move(.down); return nil
            case kVK_UpArrow: self.model.move(.up); return nil
            // 左右只在浏览网格时接管，搜索时留给输入框移动光标
            case kVK_LeftArrow where self.model.isBrowsing: self.model.move(.left); return nil
            case kVK_RightArrow where self.model.isBrowsing: self.model.move(.right); return nil
            case kVK_Return, kVK_ANSI_KeypadEnter: self.model.launch(); return nil
            case kVK_Escape where self.model.showingIndex: self.model.showingIndex = false; return nil
            case kVK_Escape where self.model.isBrowsing && self.model.inFolder: self.model.leaveFolder(); return nil
            // 搜索框为空时 ⌫ 返回上一级目录
            case kVK_Delete where self.model.isBrowsing && self.model.inFolder: self.model.leaveFolder(); return nil
            case kVK_Escape: self.hide(); return nil
            default: return event
            }
        }
    }
}
