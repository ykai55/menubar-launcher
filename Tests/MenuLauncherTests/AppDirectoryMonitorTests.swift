import CoreServices
import XCTest
@testable import MenuLauncher

@MainActor
final class AppDirectoryMonitorTests: XCTestCase {
    func testRealEventsForMissingRootInstallUpdateRenameDeleteAndRecreation() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("Applications")
        let app = root.appendingPathComponent("Group/Example.app")
        let renamed = root.appendingPathComponent("Group/Renamed.app")
        var next: XCTestExpectation?
        let monitor = AppDirectoryMonitor(paths: [root.path], debounce: 0.1) {
            next?.fulfill()
            next = nil
        }
        XCTAssertTrue(monitor.start())
        defer { monitor.stop() }

        func change(_ name: String, _ mutation: () throws -> Void) async throws {
            let received = expectation(description: name)
            next = received
            try mutation()
            await fulfillment(of: [received], timeout: 5)
        }
        try await change("install into initially missing applications directory") {
            try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        }
        try await change("update file inside app package") {
            try Data("updated".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        }
        try await change("atomic replacement inside app package") {
            try Data("replaced".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"), options: .atomic)
        }
        try await change("rename app") { try fm.moveItem(at: app, to: renamed) }
        try await change("delete app") { try fm.removeItem(at: renamed) }
        try await change("delete search root") { try fm.removeItem(at: root) }
        try await change("recreate search root") {
            try fm.createDirectory(at: app, withIntermediateDirectories: true)
        }
        try await change("watch remains live after root recreation") {
            try Data("ready".utf8).write(to: app.appendingPathComponent("ready"))
        }
    }

    func testBurstDebounceFilteringRecoveryAndStop() async {
        let callback = expectation(description: "one callback for a burst")
        callback.assertForOverFulfill = true
        let monitor = AppDirectoryMonitor(paths: ["/fixture/Applications"], debounce: 0.05) {
            callback.fulfill()
        }
        for _ in 0..<20 {
            monitor.receive(path: "/fixture/Applications/Example.app/Contents/Info.plist", flags: 0)
        }
        await fulfillment(of: [callback], timeout: 1)

        let ignored = expectation(description: "unrelated files and cancelled work do not refresh")
        ignored.isInverted = true
        let filtered = AppDirectoryMonitor(paths: ["/fixture/Applications"], debounce: 0.05) {
            ignored.fulfill()
        }
        filtered.receive(path: "/fixture/ApplicationsBackup/Example.app", flags: 0)
        await fulfillment(of: [ignored], timeout: 0.1)
        let stopped = expectation(description: "stop cancels pending refresh")
        stopped.isInverted = true
        let cancellable = AppDirectoryMonitor(paths: ["/fixture/Applications"], debounce: 0.05) {
            stopped.fulfill()
        }
        cancellable.receive(path: "/fixture/Applications/Example.app", flags: 0)
        cancellable.stop()
        await fulfillment(of: [stopped], timeout: 0.1)

        let recovered = expectation(description: "dropped events trigger full rescan")
        let recovery = AppDirectoryMonitor(paths: ["/fixture/Applications"], debounce: 0.01) {
            recovered.fulfill()
        }
        recovery.receive(path: "/fixture", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped))
        await fulfillment(of: [recovered], timeout: 1)
    }
}
