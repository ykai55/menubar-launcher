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
        case "--help", "-h":
            print("""
            用法: MenuLauncher [--list-apps | --check | --config-path]
              --list-apps    以 JSON 列出已安装应用及其固定/隐藏/目录状态
              --check        校验 \(ConfigStore.url.path)
              --config-path  打印配置文件路径
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
