import AppKit

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--install-update" {
    let result = MainActor.assumeIsolated {
        UpdateInstaller.runHelper(planURL: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    exit(result)
}

if let code = CLI.run(Array(CommandLine.arguments.dropFirst())) { exit(code) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // 不显示 Dock 图标
    app.run()
}
