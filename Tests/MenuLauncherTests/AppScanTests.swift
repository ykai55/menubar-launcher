import AppKit
import XCTest
@testable import MenuLauncher

@MainActor
final class AppScanTests: XCTestCase {
    private func app(_ id: String) -> AppItem {
        AppItem(name: id, url: URL(fileURLWithPath: "/fixture/\(id).app"),
                bundleID: id, icon: NSImage(), keywords: [id], words: [id], sortKey: id)
    }

    func testScanKeepsInputResponsiveAndCoalescesRequests() async {
        let started = expectation(description: "scan started")
        let completed = expectation(description: "scan completed")
        started.assertForOverFulfill = true
        completed.assertForOverFulfill = true
        let input = expectation(description: "main queue handles input during scan")
        let release = DispatchSemaphore(value: 0)
        let old = app("old")
        let new = app("new")
        var scanOnMain = false
        let model = LauncherModel(scanApps: {
            scanOnMain = Thread.isMainThread
            started.fulfill()
            // On the old implementation this branch avoids deadlocking the test.
            if !Thread.isMainThread { _ = release.wait(timeout: .now() + 2) }
            completed.fulfill()
            return [new]
        })
        model.reload(apps: [old])
        model.reload()
        await fulfillment(of: [started], timeout: 1)
        XCTAssertFalse(scanOnMain, "Scanning must not block the event tap's main run loop")
        XCTAssertEqual(model.browseItems.first?.id, Tile.app(old).id, "Keep existing apps usable while scanning")
        // Repeated manual refreshes coalesce; filesystem invalidation is tested separately.
        model.reload()
        model.reload()
        DispatchQueue.main.async {
            input.fulfill()
            release.signal()
        }
        await fulfillment(of: [input, completed], timeout: 1)
        // Let the scan's result reach the main actor.
        let applied = expectation(description: "new scan applied")
        let observation = model.$browseItems.sink { items in
            if items.contains(where: { $0.id == Tile.app(new).id }) { applied.fulfill() }
        }
        await fulfillment(of: [applied], timeout: 1)
        withExtendedLifetime(observation) {}
    }

    func testFilesystemChangesDuringScanScheduleOneFollowup() async {
        let started = expectation(description: "first scan started")
        let applied = expectation(description: "latest filesystem state installed")
        applied.assertForOverFulfill = true
        let release = DispatchSemaphore(value: 0)
        let old = app("old")
        let new = app("new")
        var calls = 0
        let model = LauncherModel(scanApps: {
            calls += 1
            if calls == 1 {
                started.fulfill()
                _ = release.wait(timeout: .now() + 3)
                return [old]
            }
            return [new]
        })
        let observation = model.$browseItems.sink { items in
            if items.contains(where: { $0.id == Tile.app(new).id }) { applied.fulfill() }
        }
        model.reload()
        await fulfillment(of: [started], timeout: 1)
        for _ in 0..<10 { model.appDirectoriesChanged() }
        release.signal()
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(calls, 2)
        withExtendedLifetime(observation) {}
    }

    func testExplicitSnapshotInvalidatesScanAndPendingFollowup() async {
        let started = expectation(description: "scan started")
        let returned = expectation(description: "scan returned")
        let release = DispatchSemaphore(value: 0)
        let old = app("old")
        let new = app("new")
        var calls = 0
        let model = LauncherModel(scanApps: {
            calls += 1
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            returned.fulfill()
            return [old]
        })
        model.reload()
        await fulfillment(of: [started], timeout: 1)
        model.appDirectoriesChanged()
        model.reload(apps: [new])
        let staleApplied = expectation(description: "stale result must not overwrite explicit snapshot")
        staleApplied.isInverted = true
        let observation = model.$browseItems.sink { items in
            if items.contains(where: { $0.id == Tile.app(old).id }) { staleApplied.fulfill() }
        }
        release.signal()
        await fulfillment(of: [returned], timeout: 1)
        await fulfillment(of: [staleApplied], timeout: 0.2)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.browseItems.first?.id, Tile.app(new).id)
        withExtendedLifetime(observation) {}
    }
}
