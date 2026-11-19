import XCTest
@testable import MenuLauncher

final class MenuBarPopupTests: XCTestCase {
    private let size = NSSize(width: 480, height: 450)

    func testIconAnchorsPanelUnderMenuItem() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 940)
        let icon = NSRect(x: 900, y: 952, width: 24, height: 24)
        let layout = Layout.menuBarPopupFrame(size: size, icon: icon, visibleFrame: visible)
        XCTAssertEqual(layout.frame.minX, 900)
        XCTAssertEqual(layout.frame.maxY, 948)
        XCTAssertEqual(layout.zoomAnchor, NSPoint(x: 0, y: 1))
    }

    func testHiddenIconFallsBackToMenuBarRightEdge() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 940)
        let layout = Layout.menuBarPopupFrame(size: size, icon: nil, visibleFrame: visible)
        XCTAssertEqual(layout.frame.maxX, 1506)
        XCTAssertEqual(layout.frame.maxY, 936)
        XCTAssertEqual(layout.zoomAnchor, NSPoint(x: 1, y: 1))
    }

    func testFallbackStaysInsideScreenWithNegativeOrigin() {
        let visible = NSRect(x: -1728, y: -459, width: 1728, height: 1080)
        let layout = Layout.menuBarPopupFrame(size: size, icon: nil, visibleFrame: visible)
        XCTAssertEqual(layout.frame.maxX, visible.maxX - 6)
        XCTAssertEqual(layout.frame.maxY, visible.maxY - 4)
        XCTAssertGreaterThanOrEqual(layout.frame.minX, visible.minX + 6)
    }

    func testIconNearRightEdgeShiftsPanelInsideScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 940)
        let icon = NSRect(x: 1480, y: 952, width: 24, height: 24)
        let layout = Layout.menuBarPopupFrame(size: size, icon: icon, visibleFrame: visible)
        XCTAssertEqual(layout.frame.maxX, visible.maxX - 6)
        XCTAssertEqual(layout.zoomAnchor, NSPoint(x: 0, y: 1))
    }
}
