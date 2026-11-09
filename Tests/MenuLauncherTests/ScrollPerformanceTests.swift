import XCTest
import SwiftUI
@testable import MenuLauncher

@MainActor
final class ScrollPerformanceTests: XCTestCase {
    /// Opt-in: timing depends on the host. Uses real SwiftUI/AppKit layout, not a model-only loop.
    func testScrollWhileChangingSelectionFitsFrameBudget() throws {
        guard ProcessInfo.processInfo.environment["MENULAUNCHER_PERF_CHECK"] == "1" else {
            throw XCTSkip("Run with MENULAUNCHER_PERF_CHECK=1 in a release build")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["MENULAUNCHER_CONFIG"]
        let previousMode = UserDefaults.standard.string(forKey: "browseMode")
        let previousOffset = UserDefaults.standard.double(forKey: "scrollOffset.custom")
        setenv("MENULAUNCHER_CONFIG", dir.appendingPathComponent("config.json").path, 1)
        defer {
            if let previous { setenv("MENULAUNCHER_CONFIG", previous, 1) }
            else { unsetenv("MENULAUNCHER_CONFIG") }
            UserDefaults.standard.set(previousMode, forKey: "browseMode")
            UserDefaults.standard.set(previousOffset, forKey: "scrollOffset.custom")
            try? FileManager.default.removeItem(at: dir)
        }
        var config = LauncherConfig()
        config.recordUsage = false
        try ConfigStore.save(config)
        let icon = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)!
        for count in [60, 140, 240] {
            let model = LauncherModel()
            model.loadConfig()
            model.reload(apps: (0..<count).map { i in
                let name = String(format: "App %03d", i)
                return AppItem(name: name, url: URL(fileURLWithPath: "/fixture/\(i).app"),
                               bundleID: "fixture.\(i)", icon: icon, keywords: [name],
                               words: [name], sortKey: name)
            })
            model.setMode(.custom)
            model.scrollOffset = 0
            let hosting = NSHostingView(rootView: LauncherView(model: model))
            hosting.frame = NSRect(x: 0, y: 0, width: Layout.width, height: 561)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = hosting
            window.alphaValue = 0
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            func findScroll(_ view: NSView) -> NSScrollView? {
                (view as? NSScrollView) ?? view.subviews.lazy.compactMap(findScroll).first
            }
            let scroll = try XCTUnwrap(findScroll(hosting))
            for changesSelection in [false, true] {
                if changesSelection { model.selectionState.useKeyboard() }
                else { model.selectionState.usePointer() }
                var samples: [Double] = []
                for frame in 0..<80 {
                    let start = CACurrentMediaTime()
                    let y = CGFloat(frame % 40) * 7
                    scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    // Pointer movement must not select tiles. Also stress the isolated
                    // focus publisher used by keyboard navigation during scrolling.
                    if changesSelection { model.selection = (frame % 24) + 6 }
                    else { model.selectionState.usePointer() }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                    hosting.layoutSubtreeIfNeeded()
                    hosting.displayIfNeeded()
                    CATransaction.flush()
                    if frame >= 10 { samples.append((CACurrentMediaTime() - start) * 1000) }
                }
                let sorted = samples.sorted()
                let median = sorted[sorted.count / 2]
                let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
                print("SCROLL-PERF apps=\(count) selection=\(changesSelection) median=\(median)ms p95=\(p95)ms")
                if changesSelection {
                    XCTAssertLessThan(p95, 1000 / 60, "Scroll + selection exceeds the 60 Hz CPU frame budget")
                }
            }
        }
    }
}
