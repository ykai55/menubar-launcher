import Foundation

struct MousePreference: Identifiable, Equatable {
    var id = UUID()
    var button: String
    var modifiers: String
}

struct PreferencesDraft: Equatable {
    var mode: BrowseMode
    var language: AppLanguage
    var recordUsage: Bool
    var hotkeys: String
    var mouse: [MousePreference]

    init(_ config: LauncherConfig, mode: BrowseMode) {
        self.mode = mode
        language = config.language ?? .system
        recordUsage = config.recordUsage ?? true
        hotkeys = (config.hotkey ?? Shortcut.defaults).joined(separator: "\n")
        mouse = config.mouse.map { MousePreference(button: $0.button.raw, modifiers: $0.modifiers.joined(separator: "+")) }
    }

    func merging(into latest: LauncherConfig, baseline: Self) throws -> LauncherConfig {
        var config = latest
        if language != baseline.language { config.language = language }
        if recordUsage != baseline.recordUsage { config.recordUsage = recordUsage }
        if hotkeys != baseline.hotkeys {
            let keys = hotkeys.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var seen = Set<String>()
            for key in keys {
                let shortcut = Shortcut(key)
                guard shortcut.isSafe else {
                    throw PreferenceError(message: language.text("Invalid or unsafe shortcut: ", "快捷键无效或缺少修饰键：") + key)
                }
                let identity = "\(shortcut.keyCode!):\(shortcut.modifiers!)"
                guard seen.insert(identity).inserted else {
                    throw PreferenceError(message: language.text("Duplicate shortcut: ", "快捷键重复：") + key)
                }
            }
            config.hotkey = keys
        }
        if mouse != baseline.mouse {
            config.mouse = try mouse.map { row in
                let binding = MouseBinding(
                    button: ButtonRef(row.button.trimmingCharacters(in: .whitespaces)),
                    modifiers: row.modifiers.isEmpty ? [] : row.modifiers.components(separatedBy: "+")
                        .map { $0.trimmingCharacters(in: .whitespaces) })
                guard let number = binding.button.number, number >= 0, number <= Int(UInt16.max),
                      let flags = binding.flags, number >= 2 || !flags.isEmpty else {
                    throw PreferenceError(message: language.text(
                        "Invalid mouse binding. Use back, forward, middle or a nonnegative button number; left/right require modifiers.",
                        "鼠标触发无效。请填 back、forward、middle 或非负按键编号；左右键必须搭配修饰键。"))
                }
                return binding
            }
        }
        return config
    }
}

struct PreferenceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
