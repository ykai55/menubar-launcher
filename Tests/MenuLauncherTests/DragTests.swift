import XCTest
import SwiftUI
import Combine
@testable import MenuLauncher

@MainActor
final class DragTests: XCTestCase {
    private func fixture(nested: Bool = false) throws -> LauncherModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("MENULAUNCHER_CONFIG", dir.appendingPathComponent("config.json").path, 1)
        var config = LauncherConfig()
        config.folders = try (0..<60).map {
            try JSONDecoder().decode(FolderConfig.self, from: Data("{\"name\":\"Folder \($0)\"}".utf8))
        }
        if nested {
            config.folders[0].folders = try JSONDecoder().decode([FolderConfig].self,
                from: Data(#"[{"name":"Child","folders":[{"name":"Leaf"}]},{"name":"Sibling"}]"#.utf8))
        }
        config.recordUsage = false
        try ConfigStore.save(config)
        let model = LauncherModel()
        model.loadConfig()
        model.setMode(.sorted)
        model.setMode(.custom)
        model.scrollOffset = 0
        addTeardownBlock {
            unsetenv("MENULAUNCHER_CONFIG")
            try FileManager.default.removeItem(at: dir)
        }
        return model
    }

    func testDropNeverPublishesFirstCellSelection() throws {
        let model = try fixture()
        let geo = GridGeometry(entries: model.entries, count: model.browseItems.count)
        let start = CGPoint(x: geo.origins[8].x + 30, y: geo.origins[8].y + 30)
        let end = CGPoint(x: geo.origins[14].x + 30, y: geo.origins[14].y + 30)
        model.drag(8, start: start, location: end, geo: geo)
        let key = model.tileKey(model.dragIndex!)
        var selections: [Int] = []
        let observation = model.selectionState.$index.dropFirst().sink { selections.append($0) }
        model.endDrag(location: end, inGrid: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(selections.contains(0), "Drop briefly selected first cell: \(selections)")
        XCTAssertEqual(model.tileKey(model.selection), key)
        withExtendedLifetime(observation) {}
    }

    func testEdgeDragActuallyScrollsContent() throws {
        let model = try fixture()
        let hosting = NSHostingView(rootView: LauncherView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: Layout.width, height: 561)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: hosting))
        let before = scroll.contentView.bounds.minY
        let geo = GridGeometry(entries: model.entries, count: model.browseItems.count)
        let start = CGPoint(x: geo.origins[8].x + 30, y: geo.origins[8].y + 30)
        let edge = CGPoint(x: start.x, y: before + scroll.contentView.bounds.height - Layout.padding - 5)
        let originalKeys = model.browseItems.indices.map { model.tileKey($0) }
        model.drag(8, start: start, location: edge, geo: geo)
        let screenOrigin = model.dragOrigin.y - before
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, before + 30)
        XCTAssertEqual(model.dragOrigin.y - scroll.contentView.bounds.minY, screenOrigin, accuracy: 1)

        // 静止在底边继续滚动，到内容末尾必须停住。
        let expectedBottom = geo.height + Layout.padding * 2 - scroll.contentView.bounds.height
        let deadline = Date().addingTimeInterval(3)
        // CI 的定时器调度可能晚一帧，等待实际到达边界而非假设固定帧数。
        while scroll.contentView.bounds.minY < expectedBottom - 1 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let bottom = scroll.contentView.bounds.minY
        XCTAssertEqual(bottom, expectedBottom, accuracy: 1)

        // 向上拖到顶边，必须反向滚动，图标也应留在指针下。
        let topEdge = CGPoint(x: start.x, y: bottom - Layout.padding + 5)
        model.drag(model.dragIndex!, start: .zero, location: topEdge, geo: geo)
        let topOrigin = model.dragOrigin.y - bottom
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertLessThan(scroll.contentView.bounds.minY, bottom - 30)
        XCTAssertEqual(model.dragOrigin.y - scroll.contentView.bounds.minY, topOrigin, accuracy: 1)

        model.cancelDrag()
        XCTAssertNil(model.dragIndex)
        XCTAssertEqual(model.browseItems.indices.map { model.tileKey($0) }, originalKeys)
        XCTAssertEqual(model.selection, 8)
        let stopped = scroll.contentView.bounds.minY
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(scroll.contentView.bounds.minY, stopped)
        withExtendedLifetime(window) {}
    }

    func testHideCancelsDragAndRestoresOrder() throws {
        let model = try fixture()
        let originalKeys = model.browseItems.indices.map { model.tileKey($0) }
        let geo = GridGeometry(entries: model.entries, count: model.browseItems.count)
        model.drag(8, start: geo.origins[8],
                   location: geo.origins[14], geo: geo)
        XCTAssertNotNil(model.dragIndex)
        model.resetAfterHide()
        XCTAssertNil(model.dragIndex)
        XCTAssertEqual(model.browseItems.indices.map { model.tileKey($0) }, originalKeys)
    }

    func testClickEmptyFolderViewportReturnsToParent() throws {
        let model = try fixture()
        model.openFolder([0])
        XCTAssertTrue(model.inFolder)
        let hosting = NSHostingView(rootView: LauncherView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: Layout.width, height: 561)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let point = NSPoint(x: 240, y: 120)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(model.inFolder, "Click below folder content should return to parent")
        withExtendedLifetime(window) {}
    }

    func testFolderClicksAndDragDoNotConflict() throws {
        let model = try fixture(nested: true)
        model.openFolder([0])
        let hosting = NSHostingView(rootView: LauncherView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: Layout.width, height: 561)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
        func send(_ type: NSEvent.EventType, _ point: NSPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        func click(_ point: NSPoint) throws {
            try send(.leftMouseDown, point)
            try send(.leftMouseUp, point)
            settle()
        }
        settle()
        // 图标进入子目录；下方空白只返回一级。
        try click(NSPoint(x: 45, y: 440))
        XCTAssertEqual(model.folderPath, [0, 0])
        try click(NSPoint(x: 240, y: 120))
        XCTAssertEqual(model.folderPath, [0])
        // 不足一行时的行尾空白。
        try click(NSPoint(x: 400, y: 440))
        XCTAssertEqual(model.folderPath, [])
        model.openFolder([0])
        settle()
        // 相邻格子的高亮区域之间有 4pt 间隙。
        try click(NSPoint(x: Layout.padding + Layout.cellWidth, y: 440))
        XCTAssertEqual(model.folderPath, [])
        model.openFolder([0])
        settle()
        // 从图标拖到空白处再松手，不是一次返回点击。
        try send(.leftMouseDown, NSPoint(x: 45, y: 440))
        try send(.leftMouseDragged, NSPoint(x: 80, y: 410))
        try send(.leftMouseDragged, NSPoint(x: 240, y: 200))
        try send(.leftMouseUp, NSPoint(x: 240, y: 200))
        settle()
        XCTAssertEqual(model.folderPath, [0])
        XCTAssertNil(model.dragIndex)
    }
}
