import Foundation
import os

/// Bounded, local operational logs. Formatting and disk I/O never run in an input callback.
final class DiagnosticLogger {
    let url: URL
    private let limit: Int
    private let queue = DispatchQueue(label: "menulauncher.diagnostics", qos: .utility)
    private let session = UUID().uuidString
    private let systemLog = Logger(subsystem: "local.menulauncher", category: "lifecycle")

    init(url: URL, limit: Int = 1_048_576) {
        self.url = url
        self.limit = limit
    }

    func write(_ event: String, _ fields: [String: String] = [:]) {
        let date = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var record = fields
            record["event"] = event
            record["time"] = formatter.string(from: date)
            record["uptime"] = String(format: "%.3f", uptime)
            record["pid"] = String(ProcessInfo.processInfo.processIdentifier)
            record["session"] = session
            do {
                var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
                data.append(0x0A)
                let fm = FileManager.default
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                if size + data.count > limit {
                    let previous = url.appendingPathExtension("1")
                    if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
                    if fm.fileExists(atPath: url.path) { try fm.moveItem(at: url, to: previous) }
                }
                if !fm.fileExists(atPath: url.path) {
                    fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                systemLog.error("Diagnostic log write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func flush() { queue.sync {} }
}

@MainActor
enum Diagnostics {
    static private(set) var logger: DiagnosticLogger?
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MenuLauncher/launcher.log")

    static func start() { logger = DiagnosticLogger(url: url) }
    static func record(_ event: String, _ fields: [String: String] = [:]) { logger?.write(event, fields) }
}
