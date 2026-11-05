import Foundation

/// 本地使用记录：~/.config/menulauncher/usage.jsonl，一行一个事件，只追加、不上传。
/// 应用本身不按它排序（位置要稳定），留给用户或 agent 按需参考，手动调整配置
enum UsageLog {
    static var url: URL { ConfigStore.url.deletingLastPathComponent().appendingPathComponent("usage.jsonl") }

    /// 配置里 "recordUsage": false 时不记录
    nonisolated(unsafe) static var enabled = true

    private static let queue = DispatchQueue(label: "menulauncher.usage", qos: .utility)

    /// 面板打开：trigger 为 hotkey / click
    static func panelOpened(trigger: String) {
        write(["event": "open", "trigger": trigger])
    }

    /// 启动应用：via 为 pinned / grid / folder / search，搜索时带上输入的内容，目录里带上目录路径
    static func launched(_ app: AppItem, via: String, query: String? = nil, folder: String? = nil) {
        var e: [String: Any] = ["event": "launch", "name": app.name, "path": app.url.path, "via": via]
        if let id = app.bundleID { e["bundleId"] = id }
        if let query { e["query"] = query }
        if let folder { e["folder"] = folder }
        write(e)
    }

    private static func write(_ event: [String: Any]) {
        guard enabled else { return }
        var e = event
        e["ts"] = ISO8601DateFormatter().string(from: Date())
        queue.async {
            guard var data = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return }
            data.append(0x0A)
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        }
    }

    /// 读出全部事件，坏行跳过
    static func read() -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }
}
