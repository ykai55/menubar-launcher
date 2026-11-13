import AppKit
import SwiftUI
import XCTest
@testable import MenuLauncher

@MainActor
final class PopupAnimationTests: XCTestCase {
    func testTextScaleStaysUniformAcrossRoundedWindowFrames() throws {
        try assertUniformTextScale(content: TextDrawProbe())
    }

    func testSwiftUITextScaleStaysUniformAcrossRoundedWindowFrames() throws {
        try assertUniformTextScale(content: NSHostingView(rootView:
            VStack {
                Text("字体缩放 MenuLauncher").font(.system(size: 14))
                Text("搜索应用 · 访达 · 系统设置").font(.system(size: 12))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)))
    }

    private func assertUniformTextScale(content: NSView) throws {
        content.wantsLayer = true
        let panel = DropdownPanel(content: content)
        panel.isReleasedWhenClosed = false
        let destination = NSRect(x: 180, y: 200, width: 480, height: 451)
        panel.setFrame(destination, display: true)
        panel.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let initialDraws = (content as? TextDrawProbe)?.draws ?? 0
        panel.animateIn(duration: 0.3)
        defer { panel.resetAnimation(); panel.orderOut(nil) }
        var largestScaleMismatch: CGFloat = 0
        var largestAnchorDrift: CGFloat = 0
        let layer = try XCTUnwrap(content.layer)
        let parent = try XCTUnwrap(panel.contentView?.layer)
        let end = Date().addingTimeInterval(0.35)
        while Date() < end {
            let origin = layer.convert(CGPoint.zero, to: parent)
            let x = layer.convert(CGPoint(x: 100, y: 0), to: parent)
            let y = layer.convert(CGPoint(x: 0, y: 100), to: parent)
            let sx = hypot(x.x - origin.x, x.y - origin.y) / 100
            let sy = hypot(y.x - origin.x, y.y - origin.y) / 100
            largestScaleMismatch = max(largestScaleMismatch, abs(sx - sy))
            let center = layer.convert(CGPoint(x: destination.width / 2, y: destination.height / 2), to: parent)
            largestAnchorDrift = max(largestAnchorDrift,
                abs(panel.frame.minX + center.x - destination.midX),
                abs(panel.frame.minY + center.y - destination.midY))
            XCTAssertEqual(content.bounds.size, destination.size)
            RunLoop.main.run(until: Date().addingTimeInterval(1 / 120.0))
        }
        XCTAssertLessThan(largestScaleMismatch, 0.00001,
                          "Window rounding must not stretch glyphs by different amounts on each axis")
        XCTAssertLessThan(largestAnchorDrift, 0.00001,
                          "Content must compensate for the window origin rounding")
        if let probe = content as? TextDrawProbe {
            // AppKit may repaint once when exposing the window and once when
            // settling; the animation must not invalidate drawing on every tick.
            XCTAssertLessThanOrEqual(probe.draws - initialDraws, 2,
                                     "Zoom must reuse the text backing, not redraw glyphs on every tick")
        }
    }

    func testMousePlacementAlignsIconAndKeepsItStillDuringZoom() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        let pointer = NSPoint(x: visible.midX, y: visible.midY + 180)
        let size = NSSize(width: 480, height: 450)
        let icon = NSPoint(x: 45, y: 75)
        let rect = Layout.mousePopupFrame(size: size, pointer: pointer, iconFromTop: icon, visibleFrame: visible)
        XCTAssertEqual(rect.minX + icon.x, pointer.x)
        XCTAssertEqual(rect.maxY - icon.y, pointer.y)
        let panel = DropdownPanel(content: NSView())
        panel.isReleasedWhenClosed = false
        panel.setFrame(rect, display: false)
        let anchor = NSPoint(x: icon.x / size.width, y: 1 - icon.y / size.height)
        panel.animateIn(from: anchor)
        panel.orderFrontRegardless()
        defer { panel.resetAnimation(); panel.orderOut(nil) }
        let end = Date().addingTimeInterval(0.3)
        while Date() < end {
            XCTAssertEqual(panel.frame.minX + panel.frame.width * anchor.x, pointer.x, accuracy: 1)
            XCTAssertEqual(panel.frame.minY + panel.frame.height * anchor.y, pointer.y, accuracy: 1)
            RunLoop.main.run(until: Date().addingTimeInterval(1 / 60.0))
        }
        // Negative screen origins and corners must also keep the whole popup visible.
        let secondScreen = NSRect(x: -1728, y: -450, width: 1728, height: 1080)
        for x in [secondScreen.minX, secondScreen.maxX] {
            for y in [secondScreen.minY, secondScreen.maxY] {
                let frame = Layout.mousePopupFrame(size: size, pointer: NSPoint(x: x, y: y),
                                                   iconFromTop: icon, visibleFrame: secondScreen)
                XCTAssertTrue(secondScreen.insetBy(dx: 6, dy: 6).contains(frame))
            }
        }
    }

    func testOpeningDoesNotBounceOrShiftAtScreenEdge() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        let destination = NSRect(x: visible.maxX - 486, y: visible.maxY - 456,
                                 width: 480, height: 450)
        let panel = DropdownPanel(content: NSView())
        panel.isReleasedWhenClosed = false
        panel.setFrame(destination, display: false)
        panel.animateIn()
        panel.orderFrontRegardless()
        defer { panel.resetAnimation(); panel.orderOut(nil) }
        var widths = [panel.frame.width]
        var centerDrift: CGFloat = 0
        let end = Date().addingTimeInterval(0.4)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1 / 120.0))
            widths.append(panel.frame.width)
            centerDrift = max(centerDrift, abs(panel.frame.midX - destination.midX),
                              abs(panel.frame.midY - destination.midY))
        }
        let largestReversal = zip(widths, widths.dropFirst()).map { $0 - $1 }.max() ?? 0
        XCTAssertLessThanOrEqual(widths.max()!, destination.width + 0.5, "Opening must not overshoot")
        XCTAssertLessThanOrEqual(largestReversal, 0.5, "Opening must not reverse direction")
        XCTAssertLessThanOrEqual(centerDrift, 0.5, "Edge clamping must not move the animation anchor")
        XCTAssertEqual(panel.frame, destination)
    }

    func testZoomMovesWindowMaterialAndKeepsContentLayoutStable() {
        let content = NSView()
        let panel = DropdownPanel(content: content)
        panel.isReleasedWhenClosed = false
        let destination = NSRect(x: 180, y: 200, width: 480, height: 450)
        panel.setFrame(destination, display: true)
        panel.animateIn()
        panel.orderFrontRegardless()
        defer { panel.resetAnimation(); panel.orderOut(nil) }
        XCTAssertGreaterThanOrEqual(panel.frame.width, destination.width * 0.95)
        XCTAssertLessThan(panel.frame.width, destination.width * 0.99)
        XCTAssertEqual(panel.restingFrame, destination)
        XCTAssertEqual(content.bounds.size, destination.size)
        let initialWidth = panel.frame.width
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertGreaterThan(panel.frame.width, initialWidth + 10)
        XCTAssertEqual(content.bounds.size, destination.size)
        XCTAssertEqual(panel.contentView!.frame.width, panel.frame.width, accuracy: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(panel.frame, destination)
        panel.animateOut {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertLessThan(panel.frame.width, destination.width)
        panel.animateIn()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(panel.frame, destination)
        XCTAssertEqual(panel.alphaValue, 1)
    }

    func testReopeningCancelsOldCloseAndKeepsWindowPosition() {
        let panel = DropdownPanel(content: NSView())
        panel.isReleasedWhenClosed = false
        panel.setFrame(NSRect(x: 180, y: 200, width: 480, height: 450), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        let frame = panel.frame
        panel.animateIn(duration: 0.02)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01)
        var oldCloseFinished = false
        panel.animateOut(duration: 0.05) { oldCloseFinished = true }
        panel.resetAnimation()
        panel.animateIn(duration: 0.02)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(oldCloseFinished)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(panel.frame, frame)
        var closeFinished = false
        panel.animateOut(duration: 0.02) {
            closeFinished = true
            panel.orderOut(nil)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertTrue(closeFinished)
        XCTAssertFalse(panel.isVisible)
    }

    func testPopupOverLightBackground() throws {
        guard ProcessInfo.processInfo.environment["MENULAUNCHER_POPUP_CAPTURE"] != nil else {
            throw XCTSkip("Run with MENULAUNCHER_POPUP_CAPTURE=1 for compositor capture")
        }
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        defer { app.setActivationPolicy(previousPolicy) }
        let backdrop = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 650),
                                styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.level = .floating
        backdrop.backgroundColor = NSColor(white: 0.9, alpha: 1)
        backdrop.orderFrontRegardless()
        let label = NSTextField(labelWithString: "MenuLauncher\n\nPopup animation")
        label.textColor = .white
        label.font = .systemFont(ofSize: 24)
        let content = NSView()
        content.addSubview(label)
        label.frame = NSRect(x: 30, y: 200, width: 400, height: 100)
        let panel = DropdownPanel(content: content)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setFrame(NSRect(x: 180, y: 200, width: 480, height: 450), display: true)
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil)
            backdrop.orderOut(nil)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        for phase in ["opening", "closing", "settled"] {
            panel.contentView?.layer?.speed = 1
            panel.contentView?.layer?.timeOffset = 0
            panel.resetAnimation()
            if phase == "opening" {
                panel.alphaValue = 0
                panel.animateIn(duration: 0.6)
            } else if phase == "closing" {
                panel.animateOut(duration: 0.6) {}
            } else {
                panel.animateIn(duration: 0)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if phase != "settled" {
                XCTAssertNotEqual(panel.frame.size, panel.restingFrame.size, "Capture must cover real zoom")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            let top = Int(NSScreen.screens[0].frame.maxY - backdrop.frame.maxY)
            let captureURL = FileManager.default.temporaryDirectory.appendingPathComponent("menulauncher-popup-\(UUID().uuidString).png")
            let region = "\(Int(backdrop.frame.minX)),\(top),\(Int(backdrop.frame.width)),\(Int(backdrop.frame.height))"
            process.arguments = ["-x", "-R\(region)", captureURL.path]
            // waitUntilExit pumps the run loop, letting a display link finish
            // closing before screencapture samples it. Hold this exact frame.
            let captured = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in captured.signal() }
            try process.run()
            guard captured.wait(timeout: .now() + 5) == .success else {
                process.terminate()
                XCTFail("Timed out capturing popup")
                return
            }
            try XCTSkipIf(process.terminationStatus != 0, "Display capture unavailable for \(region)")
            print("Popup compositor capture (\(phase)): \(captureURL.path)")
            let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: captureURL)))
            // Below the dark panel, its shadow should fade toward the background.
            // A bright band followed by a second dark edge is the detached white frame.
            var brightest: CGFloat = 0
            var largestDrop: CGFloat = 0
            var darkest: CGFloat = 1
            for y in Int(Double(image.pixelsHigh) * 0.55)..<Int(Double(image.pixelsHigh) * 0.95) {
                let color = try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: y)?.usingColorSpace(.deviceRGB))
                let value = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                darkest = min(darkest, value)
                if brightest > 0 { largestDrop = max(largestDrop, brightest - value) }
                if value > 0.85 { brightest = max(brightest, value) }
            }
            XCTAssertLessThan(darkest, 0.75, "The popup must be visible in the capture")
            XCTAssertLessThan(largestDrop, 0.04, "Detached light frame followed by a second shadow edge")
            if phase == "settled" {
                let scale = CGFloat(image.pixelsWide) / backdrop.frame.width
                func brightness(at point: NSPoint) throws -> CGFloat {
                    let x = Int((point.x - backdrop.frame.minX) * scale)
                    let y = Int((backdrop.frame.maxY - point.y) * scale)
                    let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    return (color.redComponent + color.greenComponent + color.blueComponent) / 3
                }
                // These pixels are outside the rounded shape on both sides of the
                // rectangular window boundary. Its shadow must remain continuous.
                for (x, dx) in [(panel.frame.minX, CGFloat(1)), (panel.frame.maxX, CGFloat(-1))] {
                    for (y, dy) in [(panel.frame.minY, CGFloat(1)), (panel.frame.maxY, CGFloat(-1))] {
                        let inner = try brightness(at: NSPoint(x: x + dx, y: y + dy))
                        let outer = try brightness(at: NSPoint(x: x - dx, y: y - dy))
                        XCTAssertLessThan(inner - outer, 0.02, "White corner at \(x), \(y)")
                    }
                }
            }
        }
    }
}

private final class TextDrawProbe: NSView {
    var draws = 0
    override func draw(_ dirtyRect: NSRect) {
        draws += 1
        ("字体缩放 MenuLauncher" as NSString).draw(at: NSPoint(x: 24, y: 100),
            withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])
    }
}
