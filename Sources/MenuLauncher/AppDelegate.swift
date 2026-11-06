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

    /// 以 anchor（窗口坐标，左下为原点）为中心缩放 s、再上移 dy 的变换。
    /// 变换是相对图层 anchorPoint 算的，先换算到它的坐标系
    private func transform(scale s: CGFloat, dy: CGFloat, around anchor: CGPoint) -> CATransform3D {
        guard let layer = contentView?.layer else { return CATransform3DIdentity }
        let a = CGPoint(x: anchor.x - layer.anchorPoint.x * layer.bounds.width,
                        y: anchor.y - layer.anchorPoint.y * layer.bounds.height)
        var m = CATransform3DMakeTranslation(a.x, a.y + dy, 0)
        m = CATransform3DScale(m, s, s, 1)
        return CATransform3DTranslate(m, -a.x, -a.y, 0)
    }

    /// 弹出：从触发点（菜单栏图标或鼠标）略小、略高的位置弹簧式落下展开，带一点回弹
    func animateIn(from anchor: CGPoint) {
        guard let layer = contentView?.layer else { return }
        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = transform(scale: 0.86, dy: 14, around: anchor)
        spring.toValue = CATransform3DIdentity
        spring.mass = 1
        spring.stiffness = 420
        spring.damping = 24
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pop")

        alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            // 窗口阴影按内容形状算，缩放期间对不上，展开完重新算一次
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.invalidateShadow() }
        })
    }

    /// 收起：朝触发点快速缩小淡出，结束后调用 done
    func animateOut(to anchor: CGPoint, done: @escaping () -> Void) {
        guard let layer = contentView?.layer else { done(); return }
        let end = transform(scale: 0.95, dy: 6, around: anchor)
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = layer.presentation()?.transform ?? CATransform3DIdentity
        shrink.toValue = end
        shrink.duration = 0.1
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.removeAllAnimations()
        layer.transform = end
        layer.add(shrink, forKey: "pop")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: done)
    }

    /// 立即复原，打断收起动画重新打开时用
    func resetAnimation() {
        contentView?.layer?.removeAllAnimations()
        contentView?.layer?.transform = CATransform3DIdentity
    }

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
    private var hotKeys: [HotKey] = []
    private var mouseTrigger: MouseTrigger!
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?

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
        model.onOpenSettings = { [weak self] in self?.openSettings() }
        // objectWillChange 在属性改变前触发，放到下一轮 runloop 再读新高度
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.resize() }
            .store(in: &cancellables)
        mouseTrigger = MouseTrigger { [weak self] in self?.toggle(trigger: "mouse") }
        model.$config
            .map(\.mouse)
            .removeDuplicates()
            .sink { [weak self] list in
                // 左右键不带修饰键会吞掉所有普通点击，直接忽略（--check 会提示）
                self?.mouseTrigger.bindings = list.compactMap { m in
                    guard let n = m.button.number, n >= 0, let f = m.flags, n >= 2 || !f.isEmpty else { return nil }
                    return (n, f)
                }
            }
            .store(in: &cancellables)
        // 快捷键也来自配置，默认 ⌥Space，改了配置立即重新注册
        model.$config
            .map { $0.shortcuts.filter(\.isSafe) }
            .removeDuplicates()
            .sink { [weak self] list in
                // 先释放旧的再注册，同一个组合键才能重新注册上
                self?.hotKeys = []
                self?.model.failedShortcuts = []
                self?.hotKeys = list.compactMap { s in
                    let key = HotKey(keyCode: s.keyCode!, modifiers: s.modifiers!) { [weak self] in
                        MainActor.assumeIsolated { self?.toggle(trigger: "hotkey") }
                    }
                    if key == nil { self?.model.failedShortcuts.append(s.raw) }
                    return key
                }
            }
            .store(in: &cancellables)
        model.loadConfig()
        model.reload()
        model.$config.map(\.language).removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMenus() }
            .store(in: &cancellables)
        updateMenus()
        if CommandLine.arguments.contains("--settings") { openSettings() }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggle(trigger: "click")
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: model.language.text("Settings…", "设置…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: model.language.text("Rescan apps", "重新扫描应用"), action: #selector(rescan), keyEquivalent: "r").target = self
        menu.addItem(withTitle: model.language.text("Edit config…", "编辑配置文件…"), action: #selector(editConfig), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: model.language.text("Quit", "退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func rescan() { model.reload() }

    @objc private func editConfig() { model.openConfig() }

    @objc func openSettings() {
        hide()
        model.cancelDrag()
        if let window = settingsWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = settingsWindow ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = model.language.text("MenuLauncher Settings", "MenuLauncher 设置")
        window.contentView = NSHostingView(rootView: SettingsView(model: model) { [weak window] in window?.close() })
        if settingsWindow == nil { window.center() }
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func updateMenus() {
        let language = model.language
        settingsWindow?.title = language.text("MenuLauncher Settings", "MenuLauncher 设置")
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: language.text("Settings…", "设置…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        app.addItem(withTitle: language.text("Quit MenuLauncher", "退出 MenuLauncher"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = app
        main.addItem(appItem)
        let edit = NSMenu(title: language.text("Edit", "编辑"))
        for (en, zh, selector, key) in [
            ("Undo", "撤销", "undo:", "z"), ("Cut", "剪切", "cut:", "x"),
            ("Copy", "复制", "copy:", "c"), ("Paste", "粘贴", "paste:", "v"),
            ("Select All", "全选", "selectAll:", "a")
        ] {
            edit.addItem(withTitle: language.text(en, zh), action: Selector(selector), keyEquivalent: key)
        }
        let redo = edit.addItem(withTitle: language.text("Redo", "重做"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func toggle(trigger: String) {
        panel.isVisible && !hiding ? hide() : show(trigger: trigger)
    }

    /// 收起动画进行中。这期间窗口还可见，再次触发应该是打开
    private var hiding = false
    /// 弹出 / 收起动画的中心点（窗口坐标）：菜单栏图标下方或鼠标处
    private var popAnchor = CGPoint.zero

    private func show(trigger: String) {
        if hiding {
            hiding = false
            panel.resetAnimation()
        }
        UsageLog.panelOpened(trigger: trigger)
        model.prepareForShow()
        resize()
        if trigger == "mouse" { positionAtMouse() } else { positionUnderStatusItem() }
        panel.makeKeyAndOrderFront(nil)
        panel.animateIn(from: popAnchor)
        if trigger != "mouse" { statusItem.button?.highlight(true) }
        installKeyMonitor()
    }

    /// 面板常驻，关闭只是隐藏。重置和重扫都放在隐藏之后做，打开时不再有额外工作
    private func hide() {
        guard panel.isVisible, !hiding else { return }
        hiding = true
        statusItem.button?.highlight(false)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.animateOut(to: popAnchor) { [weak self] in
            MainActor.assumeIsolated {
                // 收起途中又被打开了
                guard let self, self.hiding else { return }
                self.hiding = false
                self.panel.orderOut(nil)
                self.panel.resetAnimation()
                self.model.resetAfterHide()
                self.model.reloadIfStale()
            }
        }
    }

    /// 面板左上角放在鼠标处，超出所在屏幕时往回收
    private func positionAtMouse() {
        let p = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main!
        let v = screen.visibleFrame
        let x = min(max(p.x, v.minX + 6), v.maxX - panel.frame.width - 6)
        let top = max(min(p.y, v.maxY - 6), v.minY + panel.frame.height + 6)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
        popAnchor = CGPoint(x: min(max(p.x - x, 0), panel.frame.width), y: min(max(p.y - (top - panel.frame.height), 0), panel.frame.height))
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
        popAnchor = CGPoint(x: buttonRect.midX - x, y: panel.frame.height)
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
            // 应用没有菜单栏，"编辑"菜单里的 ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z 不会生效，这里手动转给输入框
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command && event.charactersIgnoringModifiers == "," {
                self.openSettings()
                return nil
            }
            if flags == .command || flags == [.command, .shift] {
                let action: Selector? = switch (event.charactersIgnoringModifiers?.lowercased(), flags.contains(.shift)) {
                case ("a", false): #selector(NSText.selectAll(_:))
                case ("c", false): #selector(NSText.copy(_:))
                case ("v", false): #selector(NSText.paste(_:))
                case ("x", false): #selector(NSText.cut(_:))
                case ("z", false): Selector(("undo:"))
                case ("z", true): Selector(("redo:"))
                default: nil
                }
                if let action, NSApp.sendAction(action, to: nil, from: self) { return nil }
            }
            switch Int(event.keyCode) {
            case kVK_DownArrow: self.model.move(.down); return nil
            case kVK_UpArrow: self.model.move(.up); return nil
            // 左右只在浏览网格时接管，搜索时留给输入框移动光标
            case kVK_LeftArrow where self.model.isBrowsing: self.model.move(.left); return nil
            case kVK_RightArrow where self.model.isBrowsing: self.model.move(.right); return nil
            case kVK_Return, kVK_ANSI_KeypadEnter: self.model.launch(); return nil
            // Tab 在目录 / 音序模式之间切换
            case kVK_Tab where self.model.isBrowsing: self.model.setMode(self.model.mode.other); return nil
            case kVK_Escape where self.model.showingIndex: self.model.showingIndex = false; return nil
            case kVK_Escape where self.model.isBrowsing && self.model.canGoBack: self.model.leaveFolder(); return nil
            // 搜索框为空时 ⌫ 返回上一级目录
            case kVK_Delete where self.model.isBrowsing && self.model.canGoBack: self.model.leaveFolder(); return nil
            // 有搜索内容时 Esc 先清空，再按一次才收起面板
            case kVK_Escape where !self.model.isBrowsing: self.model.query = ""; return nil
            case kVK_Escape: self.hide(); return nil
            default: return event
            }
        }
    }
}
