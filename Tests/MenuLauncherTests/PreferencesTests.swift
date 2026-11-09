import XCTest
import AppKit
@testable import MenuLauncher

@MainActor
final class PreferencesTests: XCTestCase {
    private func fixture() throws -> LauncherModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["MENULAUNCHER_CONFIG"]
        let previousMode = UserDefaults.standard.object(forKey: "browseMode")
        setenv("MENULAUNCHER_CONFIG", dir.appendingPathComponent("config.json").path, 1)
        try ConfigStore.save(LauncherConfig())
        let model = LauncherModel()
        model.loadConfig()
        model.reload(apps: [])
        addTeardownBlock {
            UserDefaults.standard.set(previousMode, forKey: "browseMode")
            if let previous { setenv("MENULAUNCHER_CONFIG", previous, 1) }
            else { unsetenv("MENULAUNCHER_CONFIG") }
            try FileManager.default.removeItem(at: dir)
        }
        return model
    }

    func testOldConfigAndLanguageRoundTrip() throws {
        let old = try JSONDecoder().decode(LauncherConfig.self, from: Data(#"{"hotkey":"f13"}"#.utf8))
        XCTAssertNil(old.language)
        XCTAssertEqual(PreferencesDraft(old, mode: .sorted).language, .system)
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["zh-Hant-TW", "en"]), .chinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["fr-FR", "en-US"]), .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["ja"]), .english)
        for language in AppLanguage.allCases {
            var config = old
            config.language = language
            XCTAssertEqual(try JSONDecoder().decode(LauncherConfig.self, from: JSONEncoder().encode(config)), config)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(LauncherConfig.self, from: Data(#"{"language":"invalid"}"#.utf8)))
    }

    func testSaveMergesExternalOrganizationAndUnchangedPreferences() throws {
        let model = try fixture()
        let baseline = PreferencesDraft(model.config, mode: model.mode)
        var draft = baseline
        draft.language = .english
        let external = try JSONDecoder().decode(LauncherConfig.self, from: Data("""
        {"pinned":["Safari"],"hidden":["Chess"],"order":["folder:开发","Safari"],
         "folders":[{"name":"开发","apps":["Terminal"],"order":["Terminal"],"hidden":true}],
         "recordUsage":false,"hotkey":["f15"],"mouse":[{"button":"forward"}]}
        """.utf8))
        try ConfigStore.save(external)
        try model.savePreferences(draft, baseline: baseline)
        var expected = external
        expected.language = .english
        XCTAssertEqual(try ConfigStore.load(), expected)
        XCTAssertEqual(model.config, expected)
        XCTAssertEqual(model.language, .english)
    }

    func testInvalidSettingsLeaveDiskAndModelUntouched() throws {
        let model = try fixture()
        let baseline = PreferencesDraft(model.config, mode: model.mode)
        let original = try Data(contentsOf: ConfigStore.url)
        for keys in ["a", "super+space", "option+space\nalt+space"] {
            var draft = baseline
            draft.hotkeys = keys
            XCTAssertThrowsError(try model.savePreferences(draft, baseline: baseline))
            XCTAssertEqual(try Data(contentsOf: ConfigStore.url), original)
            XCTAssertEqual(model.config, LauncherConfig())
        }
        for row in [
            MousePreference(button: "-1", modifiers: "option"),
            MousePreference(button: "0", modifiers: ""),
            MousePreference(button: "back", modifiers: "super"),
            MousePreference(button: "unknown", modifiers: "")
        ] {
            var draft = baseline
            draft.mouse = [row]
            XCTAssertThrowsError(try model.savePreferences(draft, baseline: baseline))
            XCTAssertEqual(try Data(contentsOf: ConfigStore.url), original)
        }
    }

    func testUnreadableOrInvalidConfigIsNotOverwritten() throws {
        let model = try fixture()
        let baseline = PreferencesDraft(model.config, mode: model.mode)
        var draft = baseline
        draft.recordUsage = false
        let invalid = Data("{invalid".utf8)
        try invalid.write(to: ConfigStore.url)
        XCTAssertThrowsError(try model.savePreferences(draft, baseline: baseline))
        XCTAssertEqual(try Data(contentsOf: ConfigStore.url), invalid)
        XCTAssertEqual(model.config, LauncherConfig())
        try FileManager.default.removeItem(at: ConfigStore.url)
        try FileManager.default.createDirectory(at: ConfigStore.url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try model.savePreferences(draft, baseline: baseline))
        XCTAssertEqual(model.config, LauncherConfig())
    }

    func testSaveFailureDoesNotApplyPreferences() throws {
        let model = try fixture()
        let originalURL = ConfigStore.url
        let blockedParent = originalURL.deletingLastPathComponent().appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blockedParent)
        setenv("MENULAUNCHER_CONFIG", blockedParent.appendingPathComponent("config.json").path, 1)
        defer { setenv("MENULAUNCHER_CONFIG", originalURL.path, 1) }
        let baseline = PreferencesDraft(model.config, mode: model.mode)
        var draft = baseline
        draft.language = .chinese
        draft.mode = baseline.mode.other
        XCTAssertThrowsError(try model.savePreferences(draft, baseline: baseline))
        XCTAssertEqual(model.config, LauncherConfig())
        XCTAssertEqual(model.mode, baseline.mode)
    }

    func testShortcutPunctuationDisableAndMouseRoundTrip() throws {
        let model = try fixture()
        var baseline = PreferencesDraft(model.config, mode: model.mode)
        var draft = baseline
        draft.hotkeys = "command+,\nf13"
        draft.mouse = [MousePreference(button: "0", modifiers: "option+shift"),
                       MousePreference(button: "forward", modifiers: "")]
        try model.savePreferences(draft, baseline: baseline)
        XCTAssertEqual(try ConfigStore.load()?.hotkey, ["command+,", "f13"])
        XCTAssertEqual(model.config.mouse.map(\.button.number), [0, 4])
        baseline = PreferencesDraft(model.config, mode: model.mode)
        draft = baseline
        draft.hotkeys = ""
        draft.mouse = []
        try model.savePreferences(draft, baseline: baseline)
        XCTAssertEqual(try ConfigStore.load()?.hotkey, [])
        XCTAssertEqual(try ConfigStore.load()?.mouse, [])
    }

    func testLanguageRefreshKeepsSectionIDsAndFolderNames() throws {
        let model = try fixture()
        var config = model.config
        config.pinned = ["Alpha"]
        try ConfigStore.save(config)
        model.loadConfig()
        model.reload(apps: [
            AppItem(name: "Alpha", url: URL(fileURLWithPath: "/fixture/Alpha.app"),
                    bundleID: "Alpha", icon: NSImage(), keywords: ["alpha"], words: ["alpha"], sortKey: "alpha")
        ])
        model.setMode(.sorted)
        let ids = model.entries.map(\.id)
        let baseline = PreferencesDraft(model.config, mode: model.mode)
        var draft = baseline
        draft.language = .english
        try model.savePreferences(draft, baseline: baseline)
        XCTAssertEqual(model.entries.map(\.id), ids)
        XCTAssertEqual(model.language.section("固定"), "Pinned")
        model.jump(to: "固定")
        XCTAssertEqual(model.scrollRequest?.rowID, "h:固定")
        model.setShowingHidden(true)
        guard case .back(let label) = model.entries.first?.kind else { return XCTFail("Missing back bar") }
        XCTAssertEqual(label, "Hidden items")
    }

    func testModeSavePersistsAndUneditedModeKeepsPanelChanges() throws {
        let model = try fixture()
        model.setMode(.sorted)
        let baseline = PreferencesDraft(model.config, mode: model.mode)
        var draft = baseline
        draft.mode = .custom
        XCTAssertEqual(model.mode, .sorted, "Editing a draft must not switch the launcher")
        try model.savePreferences(draft, baseline: baseline)
        XCTAssertEqual(model.mode, .custom)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "browseMode"), "custom")
        let reopened = LauncherModel()
        reopened.loadConfig()
        XCTAssertEqual(reopened.mode, .custom)

        let current = PreferencesDraft(model.config, mode: model.mode)
        var languageOnly = current
        languageOnly.language = .chinese
        model.setMode(.sorted)
        try model.savePreferences(languageOnly, baseline: current)
        XCTAssertEqual(model.mode, .sorted, "Saving another preference must keep a mode changed outside settings")
    }
}
