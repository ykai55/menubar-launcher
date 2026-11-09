import XCTest
import Combine
import AppKit
@testable import MenuLauncher

@MainActor
final class SelectionTests: XCTestCase {
    func testSelectionDoesNotInvalidateGridOrWindowObservers() {
        let model = LauncherModel()
        var layoutChanges = 0
        let observation = model.objectWillChange.sink { layoutChanges += 1 }
        // LauncherView, every Reorderable modifier, and AppDelegate's resize
        // subscription all observe this publisher.
        for index in 1...80 { model.selection = index }
        XCTAssertEqual(model.selection, 80)
        XCTAssertEqual(layoutChanges, 0, "Focus must update without invalidating the whole grid")
        withExtendedLifetime(observation) {}
    }

    func testSelectionPublishesChangedIndicesForHighlightsOnly() {
        let model = LauncherModel()
        var indices: [Int] = []
        let observation = model.selectionState.$index.sink { indices.append($0) }
        model.selection = 3
        model.selection = 3
        model.selection = 8
        model.selection = 0
        XCTAssertEqual(indices, [0, 3, 8, 0])
        withExtendedLifetime(observation) {}
    }

    func testPointerHidesKeyboardOutlineWithoutSelectingOrPublishingRepeatedly() {
        let model = LauncherModel()
        model.selection = 4
        XCTAssertFalse(model.selectionState.outlines(4))
        model.selectionState.useKeyboard()
        XCTAssertTrue(model.selectionState.outlines(4))
        XCTAssertFalse(model.selectionState.outlines(0))
        var layoutChanges = 0
        var focusChanges = 0
        let layout = model.objectWillChange.sink { layoutChanges += 1 }
        let focus = model.selectionState.objectWillChange.sink { focusChanges += 1 }
        for _ in 0..<80 { model.selectionState.usePointer() }
        XCTAssertEqual(model.selection, 4)
        XCTAssertFalse(model.selectionState.outlines(4))
        XCTAssertEqual(layoutChanges, 0)
        XCTAssertEqual(focusChanges, 1)
        model.selectionState.useKeyboard()
        XCTAssertTrue(model.selectionState.outlines(4))
        model.prepareForShow()
        XCTAssertFalse(model.selectionState.showsKeyboardFocus)
        withExtendedLifetime((layout, focus)) {}
    }

    func testArrowNavigationShowsOutlineAndSearchUsesSameFocus() {
        let model = LauncherModel()
        model.reload(apps: (0..<12).map { i in
            AppItem(name: "App \(i)", url: URL(fileURLWithPath: "/fixture/\(i).app"),
                    bundleID: "fixture.\(i)", icon: NSImage(), keywords: ["app"],
                    words: ["app"], sortKey: String(format: "%02d", i))
        })
        model.selection = 0
        model.move(.right)
        XCTAssertEqual(model.selection, 1)
        XCTAssertTrue(model.selectionState.outlines(1))
        model.selectionState.usePointer()
        model.move(.left)
        XCTAssertEqual(model.selection, 0)
        XCTAssertTrue(model.selectionState.outlines(0))
        model.query = "app"
        model.move(.down)
        XCTAssertEqual(model.selection, 1)
        XCTAssertTrue(model.selectionState.outlines(1))
        model.resetAfterHide()
        XCTAssertFalse(model.selectionState.showsKeyboardFocus)
    }
}
