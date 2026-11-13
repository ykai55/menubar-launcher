import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// 菜单样式的无边框面板：毛玻璃背景 + 圆角，不激活本应用也能接收键盘输入。
final class DropdownPanel: NSPanel {
    var onResignKey: (() -> Void)?
    private var animationGeneration = 0
    private var animationDisplayLink: CADisplayLink?
    private var animationStep: ((TimeInterval) -> Void)?
    private var targetFrame: NSRect?
    private var anchor = NSPoint(x: 0.5, y: 0.5)
    private let scalingView = NSView()
    private let hostedContent: NSView
    var restingFrame: NSRect { targetFrame ?? frame }

    init(content: NSView) {
        hostedContent = content
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
        acceptsMouseMovedEvents = true

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        // Layer clipping only rounds the foreground. WindowServer also needs an
        // alpha mask for the behind-window material and its shadow silhouette.
        let radius: CGFloat = 10
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1),
                           flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        effect.maskImage = mask
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor

        // Scale the coordinate system of the content, keeping SwiftUI's logical
        // layout stable while the actual window and its material change size.
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = []
        scalingView.addSubview(content)
        effect.addSubview(scalingView)
        contentView = effect
        layoutContent(size: frame.size)
    }

    override var canBecomeKey: Bool { true }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        resetAnimation()
        super.setFrame(frameRect, display: flag)
        layoutContent(size: frameRect.size)
    }

    private func layoutContent(size: NSSize, scale: CGFloat = 1, offset: NSPoint = .zero) {
        scalingView.frame = contentView?.bounds ?? .zero
        scalingView.bounds = NSRect(origin: .zero, size: size)
        hostedContent.frame = NSRect(origin: .zero, size: size)
        guard let layer = hostedContent.layer, size.width > 0, size.height > 0 else { return }
        // Keep AppKit's pixel-aligned backing and stable logical bounds. Correct
        // its independently rounded X/Y scales in the compositor; fractional
        // NSView frames instead trigger repeated text rasterization.
        let sx = scalingView.frame.width / size.width
        let sy = scalingView.frame.height / size.height
        guard sx > 0, sy > 0 else { return }
        let cx = scale / sx
        let cy = scale / sy
        let transform = CGAffineTransform(a: cx, b: 0, c: 0, d: cy,
            tx: (cx - 1) * layer.bounds.width * layer.anchorPoint.x - offset.x / sx,
            ty: (cy - 1) * layer.bounds.height * layer.anchorPoint.y - offset.y / sy)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(transform)
        CATransaction.commit()
    }

    /// Resize the real window, so WindowServer's blur and shadow follow the zoom.
    func animateIn(duration: TimeInterval = 0.20, from anchor: NSPoint = NSPoint(x: 0.5, y: 0.5)) {
        self.anchor = anchor
        animate(duration: duration, opening: true, done: {})
    }

    /// Ignore a stale close completion if the user has already reopened the panel.
    func animateOut(duration: TimeInterval = 0.12, done: @escaping () -> Void) {
        animate(duration: duration, opening: false, done: done)
    }

    private func animate(duration: TimeInterval, opening: Bool, done: @escaping () -> Void) {
        let wasAnimating = animationDisplayLink != nil
        let destination = restingFrame
        let initialScale = wasAnimating ? frame.width / destination.width : (opening ? 0.96 : 1)
        let initialAlpha = opening && !wasAnimating ? 0 : alphaValue
        animationDisplayLink?.invalidate()
        animationDisplayLink = nil
        animationStep = nil
        animationGeneration += 1
        let generation = animationGeneration
        targetFrame = destination
        let started = CACurrentMediaTime()
        func step(_ progress: Double) {
            guard self.animationGeneration == generation else { return }
            // A short, monotonic ease-out: no overshoot, rebound or edge correction.
            let amount = opening ? 1 - pow(1 - progress, 3) : progress * progress
            let scale = initialScale + ((opening ? 1 : 0.98) - initialScale) * amount
            self.applyFrame(destination, scale: progress >= 1 && opening ? 1 : scale)
            self.alphaValue = opening
                ? initialAlpha + (1 - initialAlpha) * amount
                : initialAlpha * (1 - amount)
            if progress >= 1 {
                self.animationDisplayLink?.invalidate()
                self.animationDisplayLink = nil
                self.animationStep = nil
                done()
            }
        }
        step(duration <= 0 ? 1 : 0)
        guard duration > 0 else { return }
        guard let screen = screen ?? NSScreen.main else {
            step(1)
            return
        }
        animationStep = { time in step(max(0, min(1, (time - started) / duration))) }
        let link = screen.displayLink(target: self, selector: #selector(advanceAnimation(_:)))
        animationDisplayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func advanceAnimation(_ link: CADisplayLink) {
        animationStep?(link.targetTimestamp)
    }

    private func applyFrame(_ destination: NSRect, scale: CGFloat) {
        let rect = NSRect(x: destination.minX + destination.width * anchor.x * (1 - scale),
                          y: destination.minY + destination.height * anchor.y * (1 - scale),
                          width: destination.width * scale, height: destination.height * scale)
        // The destination is already constrained to its screen. All intermediate
        // frames fit inside it, so the anchor stays fixed even at the screen edge.
        super.setFrame(rect, display: false)
        layoutContent(size: destination.size, scale: scale,
                      offset: NSPoint(x: frame.minX - rect.minX, y: frame.minY - rect.minY))
        displayIfNeeded()
    }

    /// 立即复原，打断收起动画重新打开时用
    func resetAnimation() {
        animationGeneration += 1
        animationDisplayLink?.invalidate()
        animationDisplayLink = nil
        animationStep = nil
        if let targetFrame {
            super.setFrame(targetFrame, display: false)
            layoutContent(size: targetFrame.size)
        }
        targetFrame = nil
        alphaValue = 1
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
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.start()
        let started = ProcessInfo.processInfo.systemUptime
        Diagnostics.record("launch.begin", [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "accessibility": String(AXIsProcessTrusted()),
            "screens": NSScreen.screens.map { NSStringFromRect($0.frame) }.joined(separator: ";")
        ])
        defer {
            Diagnostics.record("launch.ready", ["duration_ms": String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - started) * 1000)])
        }
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
        panel.onResignKey = { [weak self] in self?.hide(reason: "resign_key") }

        model.onLaunched = { [weak self] in self?.hide() }
        model.onOpenSettings = { [weak self] in self?.openSettings() }
        model.updater.onReadyToRestart = { NSApp.terminate(nil) }
        model.updater.onNotice = { [weak self] message, isError in
            guard let self else { return }
            self.hide()
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = self.model.language.text(isError ? "Update failed" : "Software Update", isError ? "更新失败" : "软件更新")
            alert.informativeText = message
            alert.addButton(withTitle: self.model.language.text("OK", "好"))
            alert.runModal()
        }
        // objectWillChange 在属性改变前触发，放到下一轮 runloop 再读新高度
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.resize() }
            .store(in: &cancellables)
        mouseTrigger = MouseTrigger { [weak self] in self?.toggle(trigger: "mouse") }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notice in
                MainActor.assumeIsolated { self?.mouseTrigger.recover(reason: notice.name.rawValue) }
            })
        }
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
        model.startWatchingApps()
        model.reload()
        Diagnostics.record("launch.config", [
            "mouse_buttons": model.config.mouse.map { $0.button.raw }.joined(separator: ","),
            "hotkey_failures": String(model.failedShortcuts.count),
            "config_error": String(model.configError != nil)
        ])
        model.$config.map(\.language).removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMenus() }
            .store(in: &cancellables)
        updateMenus()
        Task { await model.updater.check() }
        if CommandLine.arguments.contains("--settings") { openSettings() }
    }

    @objc private func statusItemClicked() {
        Diagnostics.record("status.clicked", ["type": String(NSApp.currentEvent?.type.rawValue ?? 0)])
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggle(trigger: "click")
        }
    }

    private func showContextMenu() {
        Diagnostics.record("status.menu_open")
        defer { Diagnostics.record("status.menu_closed") }
        let menu = NSMenu()
        menu.addItem(withTitle: model.language.text("Settings…", "设置…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: model.language.text("Check for updates…", "检查更新…"), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: model.language.text("Rescan apps", "重新扫描应用"), action: #selector(rescan), keyEquivalent: "r").target = self
        menu.addItem(withTitle: model.language.text("Edit config…", "编辑配置文件…"), action: #selector(editConfig), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: model.language.text("Quit", "退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func rescan() { model.reload() }

    @objc private func checkForUpdates() {
        Task { await model.updater.check(force: true, language: model.language) }
    }

    @objc private func editConfig() { model.openConfig() }

    @objc func openSettings() {
        // Capture the launcher's screen before hiding it or activating the settings window.
        let pointer = NSEvent.mouseLocation
        let screen = (panel?.isVisible == true ? panel?.screen : nil)
            ?? NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? statusItem?.button?.window?.screen
            ?? NSScreen.main
        hide()
        model.cancelDrag()
        let window = settingsWindow ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = model.language.text("MenuLauncher Settings", "MenuLauncher 设置")
        if !window.isVisible {
            window.contentView = NSHostingView(rootView: SettingsView(model: model) { [weak window] in window?.close() })
        }
        if let visible = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        } else {
            window.center()
        }
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
        Diagnostics.record("panel.toggle", panelState.merging(["trigger": trigger]) { _, new in new })
        panel.isVisible && !hiding ? hide() : show(trigger: trigger)
    }

    /// 收起动画进行中。这期间窗口还可见，再次触发应该是打开
    private var hiding = false

    private var panelState: [String: String] {
        guard let panel else { return ["window": "not_created"] }
        return ["visible": String(panel.isVisible), "hiding": String(hiding),
                "key": String(panel.isKeyWindow), "app_active": String(NSApp.isActive),
                "alpha": String(format: "%.3f", panel.alphaValue),
                "frame": NSStringFromRect(panel.frame), "occlusion": String(panel.occlusionState.rawValue)]
    }

    private func show(trigger: String) {
        let started = ProcessInfo.processInfo.systemUptime
        Diagnostics.record("panel.show_begin", panelState.merging(["trigger": trigger]) { _, new in new })
        Task { await model.updater.check() }
        if hiding {
            hiding = false
        }
        panel.resetAnimation()
        UsageLog.panelOpened(trigger: trigger)
        model.prepareForShow(alignFirstIcon: trigger == "mouse")
        resize()
        let anchor: NSPoint
        if trigger == "mouse" {
            anchor = positionAtMouse()
        } else {
            positionUnderStatusItem()
            anchor = NSPoint(x: 0, y: 1)
        }
        // Set opacity before ordering the window in, including its first frame.
        panel.alphaValue = 0
        panel.animateIn(from: anchor)
        panel.makeKeyAndOrderFront(nil)
        if trigger != "mouse" { statusItem.button?.highlight(true) }
        installKeyMonitor()
        Diagnostics.record("panel.show_requested", panelState.merging([
            "duration_ms": String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - started) * 1000)
        ]) { _, new in new })
        let token = model.showToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.model.showToken == token, !self.hiding, self.panel.isVisible else { return }
            Diagnostics.record("panel.show_settled", self.panelState)
        }
    }

    /// 面板常驻，关闭只是隐藏。重置和重扫都放在隐藏之后做，打开时不再有额外工作
    private func hide(reason: String = "action") {
        Diagnostics.record("panel.hide_requested", panelState.merging(["reason": reason]) { _, new in new })
        guard panel.isVisible, !hiding else {
            Diagnostics.record("panel.hide_ignored", panelState)
            return
        }
        hiding = true
        statusItem.button?.highlight(false)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.animateOut { [weak self] in
            MainActor.assumeIsolated {
                // 收起途中又被打开了
                guard let self, self.hiding else { return }
                self.hiding = false
                self.panel.orderOut(nil)
                self.panel.resetAnimation()
                self.model.resetAfterHide()
                Diagnostics.record("panel.hidden", self.panelState)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.record("launch.terminate", panelState)
        mouseTrigger?.stop()
        model.stopWatchingApps()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        Diagnostics.logger?.flush()
    }

    /// 第一枚置顶图标对准鼠标；屏幕边缘优先保持窗口完整可见。
    private func positionAtMouse() -> NSPoint {
        let p = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main!
        let size = panel.frame.size
        let icon = model.firstIconFromTop ?? NSPoint(x: size.width / 2, y: size.height / 2)
        panel.setFrame(Layout.mousePopupFrame(size: size, pointer: p, iconFromTop: icon,
                                             visibleFrame: screen.visibleFrame), display: false)
        // Keep the icon still under the pointer throughout the opening animation.
        return NSPoint(x: icon.x / size.width, y: 1 - icon.y / size.height)
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
        guard panel.restingFrame.height != height else { return }
        let top = panel.restingFrame.maxY
        var frame = panel.restingFrame
        frame.size.height = height
        frame.origin.y = top - frame.size.height
        panel.setFrame(frame, display: true)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel
        ]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.type != .keyDown {
                self.model.selectionState.usePointer()
                return event
            }
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
            self.model.selectionState.useKeyboard()
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
