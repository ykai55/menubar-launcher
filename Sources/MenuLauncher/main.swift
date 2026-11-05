import AppKit

if let code = CLI.run(Array(CommandLine.arguments.dropFirst())) { exit(code) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // 不显示 Dock 图标
    app.run()
}
