import SwiftUI

enum AppLanguage: String, Codable, CaseIterable {
    case system, english = "en", chinese = "zh-Hans"

    func resolved(preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for language in preferred {
            if language.hasPrefix("zh") { return .chinese }
            if language.hasPrefix("en") { return .english }
        }
        return .english
    }

    func text(_ english: String, _ chinese: String) -> String {
        resolved() == .chinese ? chinese : english
    }

    /// Section keys are persisted in drag and scroll state; translate only their labels.
    func section(_ key: String) -> String {
        switch key {
        case "固定": return text("Pinned", "固定")
        case "应用": return text("Apps", "应用")
        default: return key
        }
    }
}

private struct LauncherLanguageKey: EnvironmentKey {
    static let defaultValue = AppLanguage.system
}

extension EnvironmentValues {
    var launcherLanguage: AppLanguage {
        get { self[LauncherLanguageKey.self] }
        set { self[LauncherLanguageKey.self] = newValue }
    }
}
