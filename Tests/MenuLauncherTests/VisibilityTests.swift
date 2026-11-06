import XCTest
import AppKit
import SwiftUI
@testable import MenuLauncher

@MainActor
final class VisibilityTests: XCTestCase {
    private func fixture(_ json: String) throws -> (LauncherModel, [AppItem]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["MENULAUNCHER_CONFIG"]
        setenv("MENULAUNCHER_CONFIG", dir.appendingPathComponent("config.json").path, 1)
        let config = try JSONDecoder().decode(LauncherConfig.self, from: Data(json.utf8))
        try ConfigStore.save(config)
        let apps = ["Alpha", "Beta", "Gamma", "Delta"].map { name in
            AppItem(name: name, url: URL(fileURLWithPath: "/fixture/\(name).app"),
                    bundleID: name, icon: NSImage(), keywords: [name.lowercased()],
                    words: [name.lowercased()], sortKey: name.lowercased())
        }
        let model = LauncherModel()
        model.loadConfig()
        model.reload(apps: apps)
        model.setMode(.custom)
        model.scrollOffset = 0
        addTeardownBlock {
            if let previous { setenv("MENULAUNCHER_CONFIG", previous, 1) }
            else { unsetenv("MENULAUNCHER_CONFIG") }
            try FileManager.default.removeItem(at: dir)
        }
        return (model, apps)
    }

    private func appNames(_ model: LauncherModel) -> [String] {
        model.browseItems.compactMap { if case .app(let app) = $0 { app.name } else { nil } }
    }

    func testCustomLayoutHasOnlyOneSeparatorAndNoIndex() throws {
        let (model, apps) = try fixture(#"{"pinned":["Alpha"]}"#)
        XCTAssertTrue(model.sectionTitles.isEmpty)
        XCTAssertFalse(model.canShowIndex)
        XCTAssertEqual(model.entries.filter { if case .divider = $0.kind { true } else { false } }.count, 1)
        let geo = GridGeometry(entries: model.entries, count: model.browseItems.count)
        XCTAssertEqual(geo.origins[0].y, 0)
        XCTAssertEqual(geo.origins[1].y, Layout.cellHeight + Layout.dividerHeight)
        model.jump(to: "固定")
        XCTAssertNil(model.scrollRequest)
        model.togglePin(apps[0])
        XCTAssertFalse(model.entries.contains { if case .divider = $0.kind { true } else { false } })
        model.setMode(.sorted)
        XCTAssertTrue(model.canShowIndex)
        XCTAssertTrue(model.sectionTitles.contains("A"))
        model.jump(to: "A")
        XCTAssertNotNil(model.scrollRequest)
    }

    func testNestedHiddenFolderNavigationSearchAndRestore() throws {
        let (model, apps) = try fixture("""
        {"pinned":["Beta"],"hidden":["Delta"],"folders":[
          {"name":"Parent","folders":[
            {"name":"Private","hidden":true,"apps":["Beta"],
             "folders":[{"name":"Child","apps":["Gamma"]}]}]}]}
        """)
        XCTAssertTrue(model.config.isHidden(apps[1]))
        XCTAssertTrue(model.config.isHidden(apps[2]))
        model.openFolder([0])
        XCTAssertTrue(model.browseItems.isEmpty)
        model.query = "beta"
        XCTAssertTrue(model.results.isEmpty)
        model.query = ""
        model.setMode(.sorted)
        XCTAssertEqual(appNames(model), ["Alpha"])
        model.setShowingHidden(true)
        XCTAssertFalse(model.canReorder)
        XCTAssertFalse(model.canShowIndex)
        XCTAssertEqual(model.browseItems.count, 2) // Private + standalone Delta
        model.openFolder([0, 0])
        XCTAssertEqual(appNames(model), ["Beta"])
        model.openFolder([0, 0, 0])
        XCTAssertEqual(appNames(model), ["Gamma"])
        XCTAssertTrue(model.leaveFolder())
        XCTAssertEqual(model.folderPath, [0, 0])
        XCTAssertTrue(model.leaveFolder())
        XCTAssertEqual(model.folderPath, [])
        XCTAssertTrue(model.showingHidden) // 返回隐藏区，不能进入普通 Parent
        model.query = "gamma"
        XCTAssertEqual(model.results.map(\.name), ["Gamma"])
        model.query = ""
        model.setFolderHidden([0, 0], false)
        XCTAssertEqual(appNames(model), ["Delta"])
        model.unhide(apps[3])
        XCTAssertTrue(model.browseItems.isEmpty)
        XCTAssertTrue(model.leaveFolder())
        XCTAssertFalse(model.showingHidden)
        model.query = "beta"
        XCTAssertEqual(model.results.map(\.name), ["Beta"])
        let saved = try XCTUnwrap(ConfigStore.load())
        XCTAssertFalse(saved.folder(at: [0, 0])!.hidden)
        XCTAssertTrue(saved.hidden.isEmpty)
    }

    func testReorderingPreservesHiddenFolderSlot() throws {
        let (model, _) = try fixture("""
        {"folders":[{"name":"Private","hidden":true}],
         "order":["Alpha","folder:Private","Beta","Gamma","Delta"]}
        """)
        let geo = GridGeometry(entries: model.entries, count: model.browseItems.count)
        model.drag(0, start: geo.origins[0], location: geo.origins[1], geo: geo)
        model.endDrag(location: geo.origins[1], inGrid: true)
        XCTAssertEqual(model.config.order, ["Beta", "folder:Private", "Alpha", "Gamma", "Delta"])
        model.setFolderHidden([0], false)
        XCTAssertEqual(model.browseItems.map {
            switch $0 { case .app(let a): a.name; case .folder(let name, _, _): name }
        }, ["Beta", "Private", "Alpha", "Gamma", "Delta"])
        model.setShowingHidden(true)
        model.resetAfterHide()
        XCTAssertFalse(model.showingHidden)
        XCTAssertFalse(model.inFolder)
    }

    func testHiddenAreaButtonAndBackNavigation() throws {
        let (model, _) = try fixture(#"{"hidden":["Delta"]}"#)
        let hosting = NSHostingView(rootView: LauncherView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: Layout.width, height: 561)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
        func click(_ point: NSPoint) throws {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            settle()
        }
        settle()
        var openedSettings = false
        model.onOpenSettings = { openedSettings = true }
        try click(NSPoint(x: 462, y: 541))
        XCTAssertTrue(openedSettings)
        XCTAssertFalse(model.showingHidden)
        try click(NSPoint(x: 438, y: 541))
        XCTAssertTrue(model.showingHidden)
        XCTAssertEqual(appNames(model), ["Delta"])
        try click(NSPoint(x: 30, y: 495))
        XCTAssertFalse(model.showingHidden)
        XCTAssertFalse(appNames(model).contains("Delta"))
        try click(NSPoint(x: 438, y: 541))
        XCTAssertTrue(model.showingHidden)
        try click(NSPoint(x: 438, y: 541))
        XCTAssertFalse(model.showingHidden)
    }

    private func hoverFolder(_ model: LauncherModel, from source: Int, to target: Int) -> CGPoint {
        let geo = GridGeometry(entries: model.entries, count: model.browseItems.count)
        let start = CGPoint(x: geo.origins[source].x + 25, y: geo.origins[source].y + 25)
        let end = CGPoint(x: geo.origins[target].x + 25, y: geo.origins[target].y + 25)
        model.drag(source, start: start, location: end, geo: geo)
        XCTAssertNil(model.folderDropTarget)
        RunLoop.main.run(until: Date().addingTimeInterval(LauncherModel.folderDropDelay + 0.08))
        XCTAssertEqual(model.folderDropTarget, target)
        return end
    }

    func testDragPinnedAppIntoFolderMovesMembershipAndPreservesPin() throws {
        let (model, _) = try fixture("""
        {"pinned":["Alpha"],"folders":[
          {"name":"Old","apps":["Alpha"],"order":["Alpha"]},
          {"name":"Target","apps":["Beta"],"folders":[{"name":"Child"}]}]}
        """)
        let original = model.config
        let end = hoverFolder(model, from: 0, to: 2) // pinned Alpha -> Target
        XCTAssertEqual(try ConfigStore.load(), original, "Hover must not write configuration")
        model.endDrag(location: end, inGrid: true)
        XCTAssertNil(model.dragIndex)
        XCTAssertNil(model.folderDropTarget)
        XCTAssertEqual(model.config.pinned, ["Alpha"])
        XCTAssertTrue(model.config.folders[0].apps.isEmpty)
        XCTAssertTrue(model.config.folders[0].order.isEmpty)
        XCTAssertEqual(model.config.folders[1].apps, ["Beta", "Alpha"])
        XCTAssertEqual(model.config.folders[1].order, ["folder:Child", "Beta", "Alpha"])
        XCTAssertEqual(try ConfigStore.load(), model.config)
        // 重复移动同一应用不能创建重复成员。
        var config = model.config
        XCTAssertTrue(config.moveApp(AppItem(name: "Alpha", url: URL(fileURLWithPath: "/fixture/Alpha.app"),
            bundleID: "Alpha", icon: NSImage(), keywords: [], words: [], sortKey: ""), into: [1]))
        XCTAssertEqual(config.folders[1].apps, ["Beta", "Alpha"])
    }

    func testDragFolderMovesSubtreeAndAdjustsDestinationIndex() throws {
        let (model, _) = try fixture("""
        {"folders":[{"name":"Source","apps":["Alpha"],"folders":[{"name":"Nested","hidden":true}]},
                    {"name":"Target","apps":["Beta"]}],
         "order":["folder:Source","folder:Target","Gamma","Delta"]}
        """)
        let subtree = model.config.folders[0]
        let end = hoverFolder(model, from: 0, to: 1)
        model.endDrag(location: end, inGrid: true)
        XCTAssertEqual(model.config.folders.count, 1)
        XCTAssertEqual(model.config.folders[0].name, "Target")
        XCTAssertEqual(model.config.folders[0].folders, [subtree])
        XCTAssertEqual(model.config.folders[0].order, ["Beta", "folder:Source"])
        XCTAssertFalse(model.config.order.contains("folder:Source"))
        guard case .folder(_, let path, _) = model.browseItems[model.selection] else {
            return XCTFail("Target directory should stay selected")
        }
        XCTAssertEqual(path, [0])
        var config = model.config
        let unchanged = config
        XCTAssertNil(config.moveFolder([0], into: [0, 0]))
        XCTAssertEqual(config, unchanged, "Cannot move a folder into its descendant")
    }

    func testFolderDropCancellationAndFinalLocationAreRespected() throws {
        let (model, _) = try fixture(#"{"folders":[{"name":"Target","apps":["Beta"]}]}"#)
        let original = model.config
        let end = hoverFolder(model, from: 1, to: 0) // Alpha -> Target
        model.endDrag(location: end, inGrid: false)
        XCTAssertEqual(model.config, original)
        XCTAssertNil(model.folderDropTarget)
        _ = hoverFolder(model, from: 1, to: 0)
        // 鼠标最后离开目标，但没有中间拖动回调，也不能使用旧目标。
        model.endDrag(location: CGPoint(x: 460, y: 80), inGrid: true)
        XCTAssertEqual(model.config.folders[0].apps, ["Beta"])
        XCTAssertNil(model.folderDropTarget)
    }

    func testWindowDragGestureMergesFoldersAfterHighlight() throws {
        let (model, _) = try fixture(#"{"folders":[{"name":"Source"},{"name":"Target"}]}"#)
        let hosting = NSHostingView(rootView: LauncherView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: Layout.width, height: 561)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        func send(_ type: NSEvent.EventType, _ x: CGFloat) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 489),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        try send(.leftMouseDown, 45)
        for x in stride(from: 48.0, through: 123.0, by: 3.0) {
            try send(.leftMouseDragged, x)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(LauncherModel.folderDropDelay + 0.1))
        XCTAssertEqual(model.folderDropTarget, 1)
        XCTAssertEqual(model.config.folders.count, 2)
        try send(.leftMouseUp, 123)
        XCTAssertNil(model.dragIndex)
        XCTAssertEqual(model.config.folders.map(\.name), ["Target"])
        XCTAssertEqual(model.config.folders.first?.folders.map(\.name), ["Source"])
        XCTAssertFalse(model.inFolder, "Dropping must not also activate folder navigation")
    }

    func testContinuousApproachDoesNotPushFolderAwayBeforeHover() throws {
        let (model, _) = try fixture(#"{"folders":[{"name":"Source"},{"name":"Target"}]}"#)
        let geo = GridGeometry(entries: model.entries, count: model.browseItems.count)
        let start = CGPoint(x: 39, y: 28)
        // 模拟真实轨迹：逐点接近，先经过排序命中圈，再进入旧的目录中央命中圈。
        for x in stride(from: 44.0, through: 117.0, by: 1.0) {
            model.drag(0, start: start, location: CGPoint(x: x, y: 28), geo: geo)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(LauncherModel.folderDropDelay + 0.08))
        XCTAssertEqual(model.folderDropTarget, 1)
        XCTAssertEqual(model.dragIndex, 0, "Folder must not move away while the pointer approaches")
        model.endDrag(location: CGPoint(x: 117, y: 28), inGrid: true)
        XCTAssertEqual(model.config.folders.map(\.name), ["Target"])
        XCTAssertEqual(model.config.folders.first?.folders.map(\.name), ["Source"])
    }

    func testHoverUsesPointerWhenGrabbingLabel() throws {
        let (model, _) = try fixture(#"{"folders":[{"name":"Source"},{"name":"Target"}]}"#)
        let geo = GridGeometry(entries: model.entries, count: model.browseItems.count)
        model.drag(0, start: CGPoint(x: 39, y: 75), location: CGPoint(x: 117, y: 28), geo: geo)
        RunLoop.main.run(until: Date().addingTimeInterval(LauncherModel.folderDropDelay + 0.08))
        XCTAssertEqual(model.folderDropTarget, 1)
        model.cancelDrag()
    }

    func testFolderEdgeReordersWhileHeldWithoutMerging() throws {
        let (model, _) = try fixture(#"{"folders":[{"name":"Source"},{"name":"Target"}]}"#)
        let geo = GridGeometry(entries: model.entries, count: model.browseItems.count)
        let edge = CGPoint(x: Layout.cellWidth * 2 - 4, y: 28)
        model.drag(0, start: CGPoint(x: 39, y: 28), location: edge, geo: geo)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(model.dragIndex, 1, "Edge hover should preview a new position before mouse-up")
        XCTAssertNil(model.folderDropTarget)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        model.endDrag(location: edge, inGrid: true)
        XCTAssertEqual(model.config.folders.count, 2)
        XCTAssertTrue(model.config.folders.allSatisfy { $0.folders.isEmpty })
        XCTAssertEqual(model.config.order.prefix(2), ["folder:Target", "folder:Source"])
    }

    func testFolderEdgeQuickReleaseReorders() throws {
        let (model, _) = try fixture(#"{"folders":[{"name":"Source"},{"name":"Target"}]}"#)
        let geo = GridGeometry(entries: model.entries, count: model.browseItems.count)
        let edge = CGPoint(x: 4, y: 28)
        model.drag(1, start: CGPoint(x: 117, y: 28), location: edge, geo: geo)
        model.endDrag(location: edge, inGrid: true)
        XCTAssertEqual(model.config.order.prefix(2), ["folder:Target", "folder:Source"])
        XCTAssertTrue(model.config.folders.allSatisfy { $0.folders.isEmpty })
    }
}
