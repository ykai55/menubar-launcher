import AppKit
import Combine
import CryptoKit
import SwiftUI
import XCTest
@testable import MenuLauncher

@MainActor
final class UpdateTests: XCTestCase {
    private let fixtureHash = String(repeating: "a", count: 64)

    private func metadata(version: String = "v0.2.6", draft: Bool = false, prerelease: Bool = false,
                          url: String? = nil, digest: String? = nil, name: String = "MenuLauncher.zip") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": version, "draft": draft, "prerelease": prerelease,
            "assets": [["name": name, "browser_download_url": url ?? "https://github.com/ykai55/menubar-launcher/releases/download/\(version)/MenuLauncher.zip",
                        "digest": digest ?? "sha256:\(fixtureHash)"]]
        ])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MenuLauncher-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testStableNumericVersionComparison() throws {
        XCTAssertTrue(ReleaseVersion("v0.2.10")! > ReleaseVersion("0.2.9")!)
        XCTAssertTrue(ReleaseVersion("1.0.0")! > ReleaseVersion("0.99.99")!)
        for invalid in ["", "0.2", "0.2.6-beta", "v", "0.2.-1", "0.2.６", "1..0", "1.0.0.0"] {
            XCTAssertNil(ReleaseVersion(invalid), invalid)
        }
        XCTAssertEqual(try AppRelease.parse(metadata(), currentVersion: "0.2.5")?.version, "0.2.6")
        for version in ["v0.2.5", "v0.2.4", "v0.2.6-beta"] {
            XCTAssertNil(try AppRelease.parse(metadata(version: version), currentVersion: "0.2.5"))
        }
        XCTAssertNil(try AppRelease.parse(metadata(draft: true), currentVersion: "0.2.5"))
        XCTAssertNil(try AppRelease.parse(metadata(prerelease: true), currentVersion: "0.2.5"))
        XCTAssertThrowsError(try AppRelease.parse(metadata(), currentVersion: ""))
    }

    func testReleaseRequiresCorrectAssetAndDigest() throws {
        for url in [
            "http://github.com/ykai55/menubar-launcher/releases/download/v0.2.6/MenuLauncher.zip",
            "https://evil.example/ykai55/menubar-launcher/releases/download/v0.2.6/MenuLauncher.zip",
            "https://github.com/other/repo/releases/download/v0.2.6/MenuLauncher.zip",
            "https://github.com/ykai55/menubar-launcher/releases/download/v0.2.4/MenuLauncher.zip"
        ] {
            XCTAssertThrowsError(try AppRelease.parse(metadata(url: url), currentVersion: "0.2.5"))
        }
        for digest in ["", "sha256:abc", "md5:\(fixtureHash)", "sha256:\(String(repeating: "g", count: 64))"] {
            XCTAssertThrowsError(try AppRelease.parse(metadata(digest: digest), currentVersion: "0.2.5"))
        }
        XCTAssertThrowsError(try AppRelease.parse(metadata(name: "MenuLauncher.dmg"), currentVersion: "0.2.5"))
        XCTAssertThrowsError(try AppRelease.parse(Data("invalid".utf8), currentVersion: "0.2.5"))
    }

    func testCheckThrottleForceAndFailuresKeepKnownUpdate() async throws {
        var calls = 0
        var fail = false
        let data = try metadata()
        let updater = AppUpdater(currentVersion: "0.2.5") {
            calls += 1
            if fail { throw URLError(.notConnectedToInternet) }
            return data
        }
        var notices: [Bool] = []
        updater.onNotice = { _, error in notices.append(error) }
        let start = Date()
        await updater.check(now: start)
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(updater.available)
        XCTAssertTrue(notices.isEmpty)
        await updater.check(now: start.addingTimeInterval(60))
        XCTAssertEqual(calls, 1)
        fail = true
        await updater.check(force: true, now: start.addingTimeInterval(120))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(notices, [true])
        XCTAssertNotNil(updater.available)
        XCTAssertFalse(updater.isChecking)
        await updater.check(now: start.addingTimeInterval(180))
        XCTAssertEqual(calls, 2)
        fail = false
        await updater.check(now: start.addingTimeInterval(1021))
        XCTAssertEqual(calls, 3)
        await updater.check(force: true)
        XCTAssertEqual(notices, [true, false])
    }

    func testConcurrentChecksAreCoalescedAndCurrentVersionHasNoButton() async throws {
        let data = try metadata(version: "v0.2.5")
        var calls = 0
        let updater = AppUpdater(currentVersion: "0.2.5") {
            calls += 1
            try await Task.sleep(for: .milliseconds(30))
            return data
        }
        async let first: Void = updater.check(force: true)
        async let second: Void = updater.check(force: true)
        _ = await (first, second)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(updater.available)
        let view = NSHostingView(rootView: UpdateButton(updater: updater))
        XCTAssertLessThan(view.fittingSize.width, 1)
    }

    func testButtonAppearsInBothLanguagesWithoutPublishingGridChanges() async throws {
        let data = try metadata()
        let updater = AppUpdater(currentVersion: "0.2.5") { data }
        let model = LauncherModel(updater: updater)
        var gridChanges = 0
        let token = model.objectWillChange.sink { gridChanges += 1 }
        await updater.check()
        for language in [AppLanguage.english, .chinese] {
            let view = NSHostingView(rootView: UpdateButton(updater: updater).environment(\.launcherLanguage, language))
            XCTAssertGreaterThan(view.fittingSize.width, 40)
            XCTAssertLessThan(view.fittingSize.width, 110)
            XCTAssertLessThan(view.fittingSize.height, Layout.searchHeight)
        }
        // The actual model-owned updater must also leave the grid's publisher untouched.
        await model.updater.check(force: true)
        XCTAssertEqual(gridChanges, 0)
        withExtendedLifetime(token) {}
    }

    func testHTTPFailuresAreRejected() {
        for status in [403, 404, 429, 500] {
            let response = HTTPURLResponse(url: URL(string: "https://github.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try AppUpdater.validateHTTP(response))
        }
    }

    func testChecksumAndSignedArchiveValidation() throws {
        let root = try temporaryDirectory()
        let app = root.appendingPathComponent("MenuLauncher.app")
        let executable = app.appendingPathComponent("Contents/MacOS/MenuLauncher")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: executable.path)
        let info: [String: Any] = ["CFBundleIdentifier": "local.menulauncher", "CFBundleExecutable": "MenuLauncher",
                                   "CFBundleShortVersionString": "0.2.6", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        let archive = root.appendingPathComponent("archive.zip")
        try UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
        let checksum = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        try UpdateInstaller.verifyChecksum(archive, expected: checksum)
        XCTAssertThrowsError(try UpdateInstaller.verifyChecksum(archive, expected: fixtureHash))
        let release = AppRelease(version: "0.2.6", downloadURL: archive, sha256: checksum)
        let stage = root.appendingPathComponent("stage")
        let prepared = try UpdateInstaller.prepare(download: archive, release: release, directory: stage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.appendingPathComponent("Contents/MacOS/MenuLauncher").path))
        let wrongVersion = AppRelease(version: "0.2.7", downloadURL: archive, sha256: checksum)
        XCTAssertThrowsError(try UpdateInstaller.prepare(download: archive, release: wrongVersion, directory: root.appendingPathComponent("wrong")))
        // A modified executable must fail signature verification, even with a matching ZIP digest.
        try Data("tampered".utf8).write(to: executable)
        let badArchive = root.appendingPathComponent("bad.zip")
        try UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, badArchive.path])
        let badHash = SHA256.hash(data: try Data(contentsOf: badArchive)).map { String(format: "%02x", $0) }.joined()
        XCTAssertThrowsError(try UpdateInstaller.prepare(download: badArchive,
            release: AppRelease(version: "0.2.6", downloadURL: badArchive, sha256: badHash),
            directory: root.appendingPathComponent("bad")))
    }

    func testReplacementAndRollbackPreserveOldApp() throws {
        for failure in ["none", "move", "launch"] {
            let root = try temporaryDirectory()
            let target = root.appendingPathComponent("MenuLauncher.app")
            let staged = root.appendingPathComponent("new.app")
            let backup = root.appendingPathComponent("previous.app")
            try Data("old".utf8).write(to: target)
            if failure != "move" { try Data("new".utf8).write(to: staged) }
            let operation = {
                try UpdateInstaller.replace(target: target, staged: staged, backup: backup) { url in
                    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
                    if failure == "launch" { throw UpdateError.command }
                }
            }
            if failure == "none" {
                try operation()
                XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
                XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "old")
            } else {
                XCTAssertThrowsError(try operation())
                XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")
                XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
            }
        }
    }

    func testStagingDirectoryUsesTargetVolumeAndPrivatePermissions() throws {
        let root = try temporaryDirectory()
        let target = root.appendingPathComponent("MenuLauncher.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let stage = try UpdateInstaller.makeStagingDirectory(target: target)
        XCTAssertEqual(stage.deletingLastPathComponent().path, root.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: stage.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertThrowsError(try UpdateInstaller.makeStagingDirectory(target: root))
    }

    func testHelperConsumesPlanReplacesAppAndCleansStaging() throws {
        let root = try temporaryDirectory()
        let target = root.appendingPathComponent("MenuLauncher.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("version"))
        let directory = try UpdateInstaller.makeStagingDirectory(target: target)
        let staged = directory.appendingPathComponent("extracted/MenuLauncher.app")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staged.appendingPathComponent("version"))
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try parent.run()
        parent.waitUntilExit()
        let planURL = directory.appendingPathComponent("plan.json")
        let plan = UpdateInstaller.Plan(target: target, staged: staged, parentPID: parent.processIdentifier, language: .english)
        try JSONEncoder().encode(plan).write(to: planURL)
        var launched = false
        let result = UpdateInstaller.runHelper(planURL: planURL) { url in
            launched = true
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path))
            XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("version"), encoding: .utf8), "new")
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("previous.app/version"), encoding: .utf8), "old")
        }
        XCTAssertEqual(result, 0)
        XCTAssertTrue(launched)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8), "new")
    }
}
