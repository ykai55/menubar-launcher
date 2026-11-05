import Foundation

/// 给 agent / 脚本用的命令行入口，不启动界面：
///   MenuLauncher --list-apps   列出已安装应用（JSON），带当前固定/隐藏/所在目录
///   MenuLauncher --check       校验配置文件，报告 JSON 错误和找不到的应用
///   MenuLauncher --config-path 打印配置文件路径
enum CLI {
    /// 处理了命令行参数就返回退出码，否则返回 nil 继续启动界面
    static func run(_ args: [String]) -> Int32? {
        switch args.first {
        case "--list-apps": return listApps()
        case "--check": return check()
        case "--config-path": print(ConfigStore.url.path); return 0
        case "--stats": return stats(days: args.count > 1 ? Int(args[1]) : nil)
        case "--help", "-h":
            print("""
            用法: MenuLauncher [--list-apps | --check | --config-path | --stats [天数]]
              --list-apps    以 JSON 列出已安装应用及其固定/隐藏/目录状态
              --check        校验 \(ConfigStore.url.path)
              --config-path  打印配置文件路径
              --stats [天数]  汇总本地使用记录（JSON），可只看最近 N 天；原始记录在 \(UsageLog.url.path)
            不带参数时启动菜单栏界面。配置文件保存后界面会自动重新读取
            """)
            return 0
        default: return nil
        }
    }

    private static func loadOrFail() -> LauncherConfig? {
        do {
            return try ConfigStore.load() ?? LauncherConfig()
        } catch {
            FileHandle.standardError.write(Data("error: \(ConfigStore.describe(error))\n".utf8))
            return nil
        }
    }

    private static func listApps() -> Int32 {
        let config = (try? ConfigStore.load()) ?? LauncherConfig()
        let folders = config.allFolders()
        let rows: [[String: Any]] = AppIndex.scan(icons: false).map { app in
            var row: [String: Any] = ["name": app.name, "path": app.url.path]
            if let id = app.bundleID { row["bundleId"] = id }
            if config.pinned.contains(where: app.matches) { row["pinned"] = true }
            if config.hidden.contains(where: app.matches) { row["hidden"] = true }
            if let f = folders.first(where: { $0.folder.apps.contains(where: app.matches) }) {
                row["folder"] = f.names.joined(separator: "/")
            }
            return row
        }
        let data = try! JSONSerialization.data(withJSONObject: rows,
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
        return 0
    }

    /// 按应用汇总启动次数、最近使用时间、启动方式和常用搜索词，按次数从多到少
    private static func stats(days: Int?) -> Int32 {
        let iso = ISO8601DateFormatter()
        let since = days.map { Date().addingTimeInterval(-Double($0) * 86400) }
        let events = UsageLog.read().filter { e in
            guard let since else { return true }
            return (e["ts"] as? String).flatMap(iso.date(from:)).map { $0 >= since } ?? false
        }

        struct Stat { var name = "", bundleID: String?, count = 0, last = "", via: [String: Int] = [:], queries: [String: Int] = [:] }
        var byPath: [String: Stat] = [:]
        var opens = 0, openTriggers: [String: Int] = [:]
        for e in events {
            switch e["event"] as? String {
            case "open":
                opens += 1
                openTriggers[e["trigger"] as? String ?? "?", default: 0] += 1
            case "launch":
                guard let path = e["path"] as? String else { continue }
                var s = byPath[path] ?? Stat()
                s.name = e["name"] as? String ?? s.name
                s.bundleID = e["bundleId"] as? String ?? s.bundleID
                s.count += 1
                s.last = max(s.last, e["ts"] as? String ?? "")
                s.via[e["via"] as? String ?? "?", default: 0] += 1
                if let q = e["query"] as? String, !q.isEmpty { s.queries[q, default: 0] += 1 }
                byPath[path] = s
            default: continue
            }
        }

        let apps: [[String: Any]] = byPath.sorted { a, b in
            a.value.count != b.value.count ? a.value.count > b.value.count : a.value.last > b.value.last
        }.map { path, s in
            var row: [String: Any] = ["name": s.name, "path": path, "launches": s.count, "lastUsed": s.last, "via": s.via]
            if let id = s.bundleID { row["bundleId"] = id }
            if !s.queries.isEmpty { row["queries"] = s.queries }
            return row
        }
        var out: [String: Any] = [
            "events": events.count,
            "panelOpens": opens, "openTriggers": openTriggers,
            "launches": byPath.values.reduce(0) { $0 + $1.count },
            "apps": apps,
        ]
        if let days { out["days"] = days }
        if let first = events.compactMap({ $0["ts"] as? String }).min() { out["since"] = first }
        let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
        return 0
    }

    private static func check() -> Int32 {
        guard FileManager.default.fileExists(atPath: ConfigStore.url.path) else {
            print("配置文件不存在：\(ConfigStore.url.path)（使用默认配置）")
            return 0
        }
        guard let config = loadOrFail() else { return 1 }

        let apps = AppIndex.scan(icons: false)
        var problems: [String] = []
        func verify(_ refs: [String], _ where_: String) {
            for r in refs where !apps.contains(where: { $0.matches(r) }) {
                problems.append("\(where_): 找不到应用 \"\(r)\"")
            }
        }
        for s in config.shortcuts {
            if !s.isValid { problems.append("hotkey: 无法识别 \"\(s.raw)\"，写法如 option+space、command+shift+l、f13") }
            else if !s.isSafe { problems.append("hotkey: \"\(s.raw)\" 没有修饰键，只有 F1–F20 可以单独使用") }
        }
        for (i, m) in config.mouse.enumerated() {
            if m.button.number == nil { problems.append("mouse[\(i)]: 无法识别的鼠标键 \"\(m.button.raw)\"，可用 back / forward / middle 或数字") }
            if m.flags == nil { problems.append("mouse[\(i)]: 修饰键只能是 command / option / control / shift") }
            if let n = m.button.number, n < 2, m.modifiers.isEmpty { problems.append("mouse[\(i)]: 左右键必须配合修饰键，否则会吞掉所有点击") }
        }
        verify(config.pinned, "pinned")
        verify(config.hidden, "hidden")
        var seenNames = Set<String>()
        for (names, folder) in config.allFolders() {
            let label = "folders/" + names.joined(separator: "/")
            if folder.name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(label): 目录名为空") }
            if !seenNames.insert(names.joined(separator: "/")).inserted { problems.append("\(label): 同级目录重名") }
            verify(folder.apps, label)
        }

        if problems.isEmpty {
            print("OK")
            return 0
        }
        problems.forEach { print("warning: \($0)") }
        return 2
    }
}
