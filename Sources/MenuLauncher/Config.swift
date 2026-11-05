import Foundation

/// 用户（或 agent）手动维护的配置，存在 ~/.config/menulauncher/config.json。
/// 应用引用可以写路径、bundle id 或应用名，见 AppItem.matches
struct LauncherConfig: Codable, Equatable {
    /// 固定在顶部的应用，按数组顺序显示
    var pinned: [String] = []
    /// 不出现在网格和搜索里的应用
    var hidden: [String] = []
    /// 目录，可以嵌套。放进目录的应用不再出现在 A–Z 分组里，但仍然能搜到
    var folders: [FolderConfig] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? []
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
        folders = try c.decodeIfPresent([FolderConfig].self, forKey: .folders) ?? []
    }

    /// 按下标路径取目录，路径失效（配置被改过）时返回 nil
    func folder(at path: [Int]) -> FolderConfig? {
        var list = folders
        var found: FolderConfig?
        for i in path {
            guard list.indices.contains(i) else { return nil }
            found = list[i]
            list = list[i].folders
        }
        return found
    }

    /// 所有目录（含子目录）及其名字路径，用于统计哪些应用已经进了目录
    func allFolders() -> [(names: [String], folder: FolderConfig)] {
        var out: [(names: [String], folder: FolderConfig)] = []
        func walk(_ list: [FolderConfig], _ prefix: [String]) {
            for f in list {
                out.append((prefix + [f.name], f))
                walk(f.folders, prefix + [f.name])
            }
        }
        walk(folders, [])
        return out
    }
}

struct FolderConfig: Codable, Equatable {
    var name: String
    var apps: [String] = []
    var folders: [FolderConfig] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
        folders = try c.decodeIfPresent([FolderConfig].self, forKey: .folders) ?? []
    }
}

enum ConfigStore {
    /// 环境变量 MENULAUNCHER_CONFIG 可以指定别的路径（测试用）
    static var url: URL {
        if let p = ProcessInfo.processInfo.environment["MENULAUNCHER_CONFIG"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/menulauncher/config.json")
    }

    /// 文件不存在时返回 nil，格式错误时抛出
    static func load() throws -> LauncherConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONDecoder().decode(LauncherConfig.self, from: data)
    }

    static func save(_ config: LauncherConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    static var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// 解码错误转成能看出位置的一句话
    static func describe(_ error: Error) -> String {
        func path(_ c: DecodingError.Context) -> String {
            c.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        }
        switch error as? DecodingError {
        case .dataCorrupted(let c)?:
            let underlying = (c.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            return "JSON 格式错误：\(underlying ?? c.debugDescription)"
        case .typeMismatch(_, let c)?, .valueNotFound(_, let c)?:
            return "\(path(c)) 类型不对：\(c.debugDescription)"
        case .keyNotFound(let key, let c)?:
            return "\(path(c)) 缺少字段 \(key.stringValue)"
        default:
            return error.localizedDescription
        }
    }
}

extension AppItem {
    /// 配置里的一项是否指向这个应用：以 / 或 ~ 开头按路径比较，否则按 bundle id 或应用名（都不区分大小写）
    func matches(_ ref: String) -> Bool {
        let r = ref.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("/") || r.hasPrefix("~") {
            let p = URL(fileURLWithPath: (r as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
            return p == url.resolvingSymlinksInPath().path
        }
        return r.caseInsensitiveCompare(bundleID ?? "") == .orderedSame || r.caseInsensitiveCompare(name) == .orderedSame
    }

    /// 写回配置时用的引用：优先 bundle id，应用挪位置也不失效
    var configRef: String { bundleID ?? url.path }
}
