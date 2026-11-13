import AppKit
import CryptoKit

enum UpdateInstaller {
    struct Plan: Codable {
        let target: URL
        let staged: URL
        let parentPID: Int32
        let language: AppLanguage
    }

    static func makeStagingDirectory(target: URL) throws -> URL {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app", fm.isWritableFile(atPath: parent.path),
              fm.isWritableFile(atPath: target.path),
              !target.path.contains("/AppTranslocation/") else { throw UpdateError.location }
        let directory = parent.appendingPathComponent(".MenuLauncher-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        } catch { throw UpdateError.location }
        return directory
    }

    static func verifyChecksum(_ file: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw UpdateError.checksum }
    }

    static func prepare(download: URL, release: AppRelease, directory: URL) throws -> URL {
        try verifyChecksum(download, expected: release.sha256)
        let extracted = directory.appendingPathComponent("extracted", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", download.path, extracted.path])
        let app = extracted.appendingPathComponent("MenuLauncher.app")
        let plist = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == "local.menulauncher",
              info?["CFBundleShortVersionString"] as? String == release.version,
              info?["CFBundleExecutable"] as? String == "MenuLauncher",
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/MenuLauncher").path)
        else { throw UpdateError.invalidBundle }
        if let minimum = info?["LSMinimumSystemVersion"] as? String {
            let current = ProcessInfo.processInfo.operatingSystemVersion
            let system = "\(current.majorVersion).\(current.minorVersion).\(current.patchVersion)"
            guard minimum.compare(system, options: .numeric) != .orderedDescending else { throw UpdateError.invalidBundle }
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        // Releases are ad-hoc signed, as with the Homebrew cask's postflight.
        try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.command }
    }

    /// Keep the old bundle until the replacement has successfully been handed to Launch Services.
    /// All renames stay on the target volume. A failed move or launch restores the old bundle.
    static func replace(target: URL, staged: URL, backup: URL, launch: (URL) throws -> Void) throws {
        let fm = FileManager.default
        try fm.moveItem(at: target, to: backup)
        do {
            try fm.moveItem(at: staged, to: target)
            try launch(target)
        } catch {
            if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: staged) }
            try fm.moveItem(at: backup, to: target)
            throw error
        }
    }

    @MainActor
    static func runHelper(planURL: URL, launch: (URL) throws -> Void = {
        try run("/usr/bin/open", ["-n", $0.path])
    }) -> Int32 {
        let fm = FileManager.default
        let directory = planURL.deletingLastPathComponent()
        var language = AppLanguage.system
        var target: URL?
        var safeToClean = false
        var parentExited = false
        defer { if safeToClean { try? fm.removeItem(at: directory) } }
        do {
            let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: planURL))
            language = plan.language
            target = plan.target
            // Accept only the private staging layout produced by this process.
            guard directory.lastPathComponent.hasPrefix(".MenuLauncher-update-"),
                  directory.deletingLastPathComponent().path == plan.target.deletingLastPathComponent().path,
                  plan.staged.path == directory.appendingPathComponent("extracted/MenuLauncher.app").path,
                  plan.target.pathExtension == "app", plan.parentPID > 1 else { throw UpdateError.helper }
            try Data().write(to: directory.appendingPathComponent("ready"), options: .atomic)
            let deadline = Date().addingTimeInterval(30)
            while kill(plan.parentPID, 0) == 0 {
                guard Date() < deadline else { throw UpdateError.helper }
                Thread.sleep(forTimeInterval: 0.1)
            }
            parentExited = true
            let backup = directory.appendingPathComponent("previous.app")
            do {
                try replace(target: plan.target, staged: plan.staged, backup: backup, launch: launch)
                safeToClean = true
            } catch {
                // If rollback itself failed, keep the backup for recovery.
                safeToClean = !fm.fileExists(atPath: backup.path)
                throw error
            }
            return 0
        } catch {
            if parentExited, let target, fm.fileExists(atPath: target.path) { try? run("/usr/bin/open", ["-n", target.path]) }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = language.text("Update failed", "升级失败")
            alert.informativeText = language.text("The update could not be completed. Your configuration is unchanged.", "未能完成升级，你的配置没有变化。")
            if !safeToClean {
                alert.informativeText += "\n" + language.text("Recovery files: ", "恢复文件：") + directory.path
            }
            alert.addButton(withTitle: language.text("OK", "好"))
            alert.runModal()
            return 1
        }
    }
}
