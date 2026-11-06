import XCTest
import AppKit
import SwiftUI
@testable import MenuLauncher

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testSettingsWindowSaveCancelAndTabsInBothLanguages() throws {
        let previous = ProcessInfo.processInfo.environment["MENULAUNCHER_CONFIG"]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("MENULAUNCHER_CONFIG", dir.appendingPathComponent("config.json").path, 1)
        defer {
            if let previous { setenv("MENULAUNCHER_CONFIG", previous, 1) }
            else { unsetenv("MENULAUNCHER_CONFIG") }
            try? FileManager.default.removeItem(at: dir)
        }
        for language in [AppLanguage.english, .chinese] {
            var config = LauncherConfig()
            config.language = language
            try ConfigStore.save(config)
            let model = LauncherModel()
            model.loadConfig()
            model.reload(apps: [])
            var cancelled = false
            let hosting = NSHostingView(rootView: SettingsView(model: model, close: { cancelled = true }))
            hosting.frame = NSRect(x: 0, y: 0, width: 580, height: 540)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.contentView = hosting
            window.alphaValue = 0
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.fittingSize, NSSize(width: 580, height: 540))
            func capture(_ suffix: String) throws {
              if let output = ProcessInfo.processInfo.environment["MENULAUNCHER_SCREENSHOT_DIR"] {
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("settings-\(language.rawValue)\(suffix).png"))
              }
            }
            func click(_ x: CGFloat, _ y: CGFloat) throws {
                func event(_ type: NSEvent.EventType) throws -> NSEvent {
                    try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                        clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                }
                // AppKit switches run a tracking loop inside mouseDown. Queue the release
                // first so that loop can finish; SwiftUI controls consume it below instead.
                NSApp.postEvent(try event(.leftMouseUp), atStart: false)
                window.sendEvent(try event(.leftMouseDown))
                if let release = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                                  inMode: .default, dequeue: true) {
                    window.sendEvent(release)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            }
            try capture("")
            try click(518, 363) // Local usage toggle.
            XCTAssertNil(model.config.recordUsage, "Changes remain a draft until Save")
            try click(538, 28)
            XCTAssertEqual(try ConfigStore.load()?.recordUsage, false)
            try click(518, 363)
            try click(480, 28)
            XCTAssertTrue(cancelled)
            XCTAssertEqual(try ConfigStore.load()?.recordUsage, false, "Cancel must not write the draft")
            try click(330, 508) // Shortcuts segment.
            try capture("-shortcuts")
            try click(520, language == .english ? 286 : 302) // Add mouse trigger.
            try click(538, 28)
            XCTAssertEqual(try ConfigStore.load()?.mouse.map(\.button.raw), ["back"])
        }
    }
}
