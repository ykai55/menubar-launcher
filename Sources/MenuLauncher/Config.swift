import Foundation

/// 用户（或 agent）手动维护的配置，存在 ~/.config/menulauncher/config.json。
/// 应用引用可以写路径、bundle id 或应用名，见 AppItem.matches
struct LauncherConfig: Codable, Equatable {
    /// 固定在顶部的应用，按数组顺序显示
    var pinned: [String] = []
    /// 不出现在网格和搜索里的应用
    var hidden: [String] = []
    /// 目录，可以嵌套。定制模式下放进目录的应用不再出现在「应用」分组里，但仍然能搜到
    var folders: [FolderConfig] = []
    /// 定制模式下顶层目录和应用（没进目录的）混排的顺序，拖动时写入。
    /// 应用写引用，目录写 "folder:目录名"；没列出的目录按 folders 顺序排在前面，没列出的应用按名字排在后面
    var order: [String] = []
    /// 是否在本地记录打开/启动事件（usage.jsonl），默认记录
    var recordUsage: Bool? = nil
    /// 呼出面板的鼠标键，面板在鼠标位置打开
    var mouse: [MouseBinding] = []
    /// 呼出面板的全局快捷键，例如 ["option+space"]。不写用默认的 ⌥Space，写 [] 表示不用快捷键。
    /// 也接受单个字符串
    var hotkey: [String]? = nil

    /// 实际生效的快捷键
    var shortcuts: [Shortcut] { (hotkey ?? Shortcut.defaults).map(Shortcut.init) }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? []
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
        folders = try c.decodeIfPresent([FolderConfig].self, forKey: .folders) ?? []
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        recordUsage = try c.decodeIfPresent(Bool.self, forKey: .recordUsage)
        mouse = try c.decodeIfPresent([MouseBinding].self, forKey: .mouse) ?? []
        if let one = try? c.decodeIfPresent(String.self, forKey: .hotkey) { hotkey = [one] }
        else { hotkey = try c.decodeIfPresent([String].self, forKey: .hotkey) }
    }

    /// 修改某个下标路径上的目录，路径失效时什么都不做
    mutating func editFolder(at path: [Int], _ body: (inout FolderConfig) -> Void) {
        func edit(_ list: inout [FolderConfig], _ p: ArraySlice<Int>) {
            guard let i = p.first, list.indices.contains(i) else { return }
            if p.count == 1 { body(&list[i]) } else { edit(&list[i].folders, p.dropFirst()) }
        }
        edit(&folders, path[...])
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
    /// 目录内子目录和应用混排的顺序，含义同 LauncherConfig.order
    var order: [String] = []

    private enum CodingKeys: String, CodingKey { case name, apps, folders, order }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
        folders = try c.decodeIfPresent([FolderConfig].self, forKey: .folders) ?? []
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
    }

    /// 空的 folders / order 不写出来，保持配置文件简洁
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(apps, forKey: .apps)
        if !folders.isEmpty { try c.encode(folders, forKey: .folders) }
        if !order.isEmpty { try c.encode(order, forKey: .order) }
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
