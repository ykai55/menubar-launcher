import AppKit
import XCTest
@testable import MenuLauncher

@MainActor
final class MouseTriggerTests: XCTestCase {
    private func event(button: Int, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                        mouseCursorPosition: .zero, mouseButton: .center))
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        event.flags = flags
        return event
    }

    func testModifiersDuplicateDownAndReleasePairing() throws {
        var calls = 0
        let trigger = MouseTrigger(listens: false) { calls += 1 }
        trigger.bindings = [(1, .maskAlternate)]
        XCTAssertTrue(trigger.handle(.rightMouseDown, try event(button: 1)) != nil)
        let down = try event(button: 1, flags: [.maskAlternate, .maskAlphaShift])
        XCTAssertNil(trigger.handle(.rightMouseDown, down))
        XCTAssertNil(trigger.handle(.rightMouseDown, down))
        // Releasing the modifier first must still swallow the paired mouse-up.
        XCTAssertNil(trigger.handle(.rightMouseUp, try event(button: 1)))
        XCTAssertTrue(trigger.handle(.rightMouseUp, try event(button: 1)) != nil)
        XCTAssertTrue(trigger.handle(.rightMouseDown, try event(button: 1, flags: [.maskAlternate, .maskShift])) != nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(calls, 1)
    }

    func testReconfigurationAndRecoveryCancelStaleDelivery() throws {
        var calls = 0
        let trigger = MouseTrigger(listens: false) { calls += 1 }
        trigger.bindings = [(3, [])]
        let down = try event(button: 3)
        XCTAssertNil(trigger.handle(.otherMouseDown, down))
        trigger.bindings = [(4, [])]
        XCTAssertNil(trigger.handle(.otherMouseUp, down))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(calls, 0)
        trigger.bindings = [(3, [])]
        XCTAssertNil(trigger.handle(.otherMouseDown, down))
        trigger.recover(reason: "test_wake")
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(calls, 0)
        XCTAssertNil(trigger.handle(.otherMouseDown, down))
        XCTAssertNil(trigger.handle(.otherMouseUp, down))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(calls, 1)
    }

    func testUIWorkRunsAfterEventTapReturns() throws {
        var insideCallback = true
        var wasReentrant = false
        var calls = 0
        let trigger = MouseTrigger(listens: false) {
            calls += 1
            wasReentrant = insideCallback
        }
        trigger.bindings = [(3, [])]
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                        mouseCursorPosition: .zero, mouseButton: .center))
        event.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        XCTAssertNil(trigger.handle(.otherMouseDown, event))
        insideCallback = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(wasReentrant, "Window layout must not block the WindowServer event tap")
        XCTAssertNil(trigger.handle(.otherMouseUp, event))
    }
}
