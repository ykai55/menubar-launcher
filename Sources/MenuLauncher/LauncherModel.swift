import AppKit
import SwiftUI

/// 浏览网格摊平后的一项：分组标题或一行图标。id 全局唯一，供 LazyVStack 复用和记录滚动位置
struct GridEntry: Identifiable {
    enum Kind {
        case header(String)
        /// 目录里顶部的返回条，显示当前目录名
        case back(String)
        /// 若干个下标，指向 browseItems
        case row([Int])
    }
    let id: String
    let kind: Kind

    var indices: [Int] {
        if case .row(let r) = kind { return r }
        return []
    }
}

/// 浏览网格里的一格：应用或目录
enum Tile: Identifiable {
    case app(AppItem)
    /// path 是目录在配置里的下标路径
    case folder(name: String, path: [Int], icons: [NSImage])

    var id: String {
        switch self {
        case .app(let a): return a.id
        case .folder(_, let path, _): return "f:" + path.map(String.init).joined(separator: ".")
        }
    }
}

struct ScrollRequest: Equatable {
    let rowID: String
    /// nil 表示滚到刚好可见即可；跳转到字母分组时用 .top，让标题贴顶
    var anchor: UnitPoint? = nil
    let token: Int
}

@MainActor
final class LauncherModel: ObservableObject {
    static let maxResults = 10

    @Published var query = "" { didSet { refilter() } }
    /// 搜索模式下的结果
    @Published private(set) var results: [AppItem] = []
    /// 浏览模式（空查询）下的全部条目：固定区 + A–Z，顺序稳定
    @Published private(set) var browseItems: [Tile] = []
    @Published private(set) var entries: [GridEntry] = []
    /// 来自 ~/.config/menulauncher/config.json，外部修改后自动重新读取
    @Published private(set) var config = LauncherConfig()
    /// 配置文件读不出来时的错误，沿用上一次读到的配置
    @Published private(set) var configError: String?
    /// 当前打开的目录（配置里的下标路径），空表示在顶层
    @Published private(set) var folderPath: [Int] = []
    @Published var selection = 0
    /// 浏览网格的滚动偏移（像素），跨次打开（包括重启）保持滚动位置。
    /// 故意不用 @Published：滚动时它会频繁变化，发布出去会让整个面板跟着重绘
    var scrollOffset: CGFloat = UserDefaults.standard.double(forKey: "scrollOffset") {
        didSet { UserDefaults.standard.set(Double(scrollOffset), forKey: "scrollOffset") }
    }
    /// 键盘移动选中项后需要滚动到的行；token 保证同一行也能重复触发
    @Published private(set) var scrollRequest: ScrollRequest?
    /// 每次面板弹出时 +1，视图据此重新聚焦搜索框
    @Published private(set) var showToken = 0
    /// 点击分组标题后显示的字母索引面板
    @Published var showingIndex = false

    /// 网格里实际存在的分组标题，按显示顺序（固定、A–Z、#）
    var sectionTitles: [String] {
        entries.compactMap { if case .header(let t) = $0.kind { return t } else { return nil } }
    }

    var inFolder: Bool { !folderPath.isEmpty }

    /// 区分顶层和各个目录，视图据此给每一层一个独立的滚动视图
    var levelKey: String { folderPath.map(String.init).joined(separator: ".") }

    func openFolder(_ path: [Int]) {
        guard config.folder(at: path) != nil else { return }
        folderPath = path
        rebuildBrowse()
        selection = 0
    }

    /// 回到上一级目录；已在顶层时返回 false
    @discardableResult
    func leaveFolder() -> Bool {
        guard inFolder else { return false }
        folderPath.removeLast()
        rebuildBrowse()
        selection = inFolder ? 0 : firstVisibleIndex()
        return true
    }

    /// 跳到某个分组：标题贴顶，选中该组第一个应用
    func jump(to title: String) {
        showingIndex = false
        guard let h = entries.firstIndex(where: { $0.id == "h:\(title)" }) else { return }
        if let first = entries[h...].lazy.compactMap(\.indices.first).first { selection = first }
        scrollRequest = ScrollRequest(rowID: entries[h].id, anchor: .top, token: (scrollRequest?.token ?? 0) + 1)
    }

    var onLaunched: (() -> Void)?

    private var apps: [AppItem] = []
    /// 去掉隐藏应用之后的，网格和搜索都只用它
    private var shownApps: [AppItem] = []
    private var lastScan = Date.distantPast
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var configDate: Date?

    var isBrowsing: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }
    var visibleCount: Int { isBrowsing ? browseItems.count : results.count }

    var preferredHeight: CGFloat {
        let banner = configError == nil ? 0 : Layout.errorHeight
        if isBrowsing {
            let rows = entries.filter { !$0.indices.isEmpty }.count
            return banner + Layout.gridHeight(headers: entries.count - rows, rows: rows)
        }
        return banner + Layout.listHeight(rows: max(results.count, 1))
    }

    func reload() {
        apps = AppIndex.scan()
        lastScan = Date()
        applyConfig()
    }

    // MARK: - 配置

    /// 读配置并开始监听。第一次运行没有配置文件时，把旧版存在 UserDefaults 里的固定项迁移过去
    func loadConfig() {
        do {
            if let c = try ConfigStore.load() {
                config = c
            } else if let old = UserDefaults.standard.stringArray(forKey: "pinned"), !old.isEmpty {
                config = LauncherConfig()
                config.pinned = old
                try ConfigStore.save(config)
            }
            configError = nil
        } catch {
            configError = ConfigStore.describe(error)
        }
        configDate = ConfigStore.modificationDate
        if dirWatcher == nil { watchConfig() }
    }

    /// 同时监听目录和文件：编辑器和 agent 常用"写临时文件再改名"的方式保存，文件会被替换，只有目录能收到；
    /// 原地写入（echo > config.json）只有文件本身能收到。文件被替换后重新打开文件监听
    private func watchConfig() {
        let dir = ConfigStore.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirWatcher = watch(dir.path, [.write])
        watchFile()
    }

    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = watch(ConfigStore.url.path, [.write, .extend, .delete, .rename])
    }

    private func watch(_ path: String, _ mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.configFileChanged() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func configFileChanged() {
        watchFile()
        let date = ConfigStore.modificationDate
        guard date != configDate else { return }
        loadConfig()
        applyConfig()
    }

    /// 配置变了（或重扫了应用）之后重算隐藏、固定、目录
    private func applyConfig() {
        shownApps = apps.filter { app in !config.hidden.contains(where: app.matches) }
        if config.folder(at: folderPath) == nil { folderPath = [] }
        rebuildBrowse()
        refilter()
    }

    /// 从界面改配置：改完立即生效并写回文件
    private func updateConfig(_ change: (inout LauncherConfig) -> Void) {
        change(&config)
        do {
            try ConfigStore.save(config)
            configError = nil
        } catch {
            configError = "保存配置失败：\(error.localizedDescription)"
        }
        configDate = ConfigStore.modificationDate
        applyConfig()
        selection = min(selection, max(visibleCount - 1, 0))
    }

    private func resolve(_ refs: [String]) -> [AppItem] {
        var seen = Set<String>()
        return refs.compactMap { ref in shownApps.first(where: { $0.matches(ref) }) }
            .filter { seen.insert($0.id).inserted }
    }

    /// 距上次扫描超过 5 分钟就重扫，用来发现新装/卸载的应用
    func reloadIfStale() {
        if Date().timeIntervalSince(lastScan) > 300 { reload() }
    }

    /// 面板隐藏后调用：清掉搜索和索引层，让网格在看不见的时候就恢复好，下次打开直接显示
    func resetAfterHide() {
        query = ""
        showingIndex = false
        if inFolder {
            folderPath = []
            rebuildBrowse()
        }
    }

    func prepareForShow() {
        selection = firstVisibleIndex()
        showToken += 1
    }

    /// 选中项落在当前可见的第一整行，避免回车启动一个看不见的应用
    private func firstVisibleIndex() -> Int {
        guard !inFolder else { return 0 }
        var y = Layout.padding
        for e in entries {
            let h = e.indices.isEmpty ? Layout.headerHeight : Layout.cellHeight
            if let first = e.indices.first, y >= scrollOffset - 1 { return first }
            y += h
        }
        return 0
    }

    /// 保存的偏移落在哪一项上（取离得近的边界），恢复时按项对齐，不会停在半行
    func entryIDForSavedOffset() -> String? {
        var y = Layout.padding
        for e in entries {
            let h = e.indices.isEmpty ? Layout.headerHeight : Layout.cellHeight
            if scrollOffset < y + h / 2 { return e.id }
            y += h
        }
        return entries.last?.id
    }

    // MARK: - 固定

    func isPinned(_ app: AppItem) -> Bool { config.pinned.contains(where: app.matches) }

    func togglePin(_ app: AppItem) {
        updateConfig { c in
            if c.pinned.contains(where: app.matches) { c.pinned.removeAll(where: app.matches) }
            else { c.pinned.append(app.configRef) }
        }
    }

    func hide(_ app: AppItem) {
        updateConfig { c in c.hidden.append(app.configRef) }
    }

    /// 从当前打开的目录里移出，回到 A–Z 分组
    func removeFromFolder(_ app: AppItem) {
        let path = folderPath
        updateConfig { c in
            func edit(_ list: inout [FolderConfig], _ p: ArraySlice<Int>) {
                guard let i = p.first, list.indices.contains(i) else { return }
                if p.count == 1 { list[i].apps.removeAll(where: app.matches) }
                else { edit(&list[i].folders, p.dropFirst()) }
            }
            edit(&c.folders, path[...])
        }
    }

    func openConfig() {
        if !FileManager.default.fileExists(atPath: ConfigStore.url.path) { try? ConfigStore.save(config) }
        NSWorkspace.shared.open(ConfigStore.url)
        onLaunched?()
    }

    func revealInFinder(_ app: AppItem) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
        onLaunched?()
    }

    // MARK: - 键盘导航

    enum Direction { case up, down, left, right }

    func move(_ dir: Direction) {
        let count = visibleCount
        guard count > 0 else { return }

        if !isBrowsing {
            // 搜索结果是单列列表，上下循环
            switch dir {
            case .up: selection = (selection - 1 + count) % count
            case .down: selection = (selection + 1) % count
            default: return
            }
            return
        }

        let rows = entries.filter { !$0.indices.isEmpty }
        guard let r = rows.firstIndex(where: { $0.indices.contains(selection) }),
              let c = rows[r].indices.firstIndex(of: selection) else { selection = 0; return }
        switch dir {
        case .left: selection = max(selection - 1, 0)
        case .right: selection = min(selection + 1, count - 1)
        case .up where r > 0: selection = rows[r - 1].indices[min(c, rows[r - 1].indices.count - 1)]
        case .down where r < rows.count - 1: selection = rows[r + 1].indices[min(c, rows[r + 1].indices.count - 1)]
        default: break
        }
        if let row = rows.first(where: { $0.indices.contains(selection) }) {
            scrollRequest = ScrollRequest(rowID: row.id, token: (scrollRequest?.token ?? 0) + 1)
        }
    }

    /// 启动选中的应用；选中的是目录就打开目录
    func launch(at index: Int? = nil) {
        let i = index ?? selection
        let app: AppItem
        if isBrowsing {
            guard browseItems.indices.contains(i) else { return }
            switch browseItems[i] {
            case .folder(_, let path, _): openFolder(path); return
            case .app(let a): app = a
            }
        } else {
            guard results.indices.contains(i) else { return }
            app = results[i]
        }

        let open = NSWorkspace.OpenConfiguration()
        open.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: open)
        onLaunched?()
    }

    // MARK: - 构建列表

    private func rebuildBrowse() {
        var items: [Tile] = []
        var entries: [GridEntry] = []

        func addRows(_ key: String, _ group: [Tile]) {
            let start = items.count
            items += group
            for (n, s) in stride(from: start, to: items.count, by: Layout.columns).enumerated() {
                let row = Array(s..<min(s + Layout.columns, items.count))
                entries.append(GridEntry(id: "r:\(key):\(n)", kind: .row(row)))
            }
        }
        func add(_ title: String, _ group: [Tile]) {
            guard !group.isEmpty else { return }
            entries.append(GridEntry(id: "h:\(title)", kind: .header(title)))
            addRows(title, group)
        }
        func folderTiles(_ list: [FolderConfig], _ prefix: [Int]) -> [Tile] {
            list.enumerated().map { i, f in
                .folder(name: f.name, path: prefix + [i], icons: resolve(f.apps).prefix(4).map(\.icon))
            }
        }

        if inFolder, let folder = config.folder(at: folderPath) {
            // 目录内：返回条 + 子目录 + 应用，按配置里的顺序
            entries.append(GridEntry(id: "b:\(levelKey)", kind: .back(folder.name)))
            addRows("f\(levelKey)", folderTiles(folder.folders, folderPath) + resolve(folder.apps).map(Tile.app))
        } else {
            add("固定", resolve(config.pinned).map(Tile.app))
            add("目录", folderTiles(config.folders, []))

            // 进了目录的应用不再出现在 A–Z 里（固定的仍然出现，固定只是快捷方式）
            let filed = Set(config.allFolders().flatMap { resolve($0.folder.apps).map(\.id) })
            let groups = Dictionary(grouping: shownApps.filter { !filed.contains($0.id) }, by: \.section)
            for letter in groups.keys.sorted(by: { ($0 == "#" ? "~" : $0) < ($1 == "#" ? "~" : $1) }) {
                add(letter, groups[letter]!.map(Tile.app))
            }
        }

        browseItems = items
        self.entries = entries
    }

    private func refilter() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            results = []
        } else {
            // 只按匹配程度排序，不掺使用频率，同一个查询结果顺序始终一致
            let scored: [(app: AppItem, score: Int)] = shownApps.compactMap { app in
                guard let s = score(app, q) else { return nil }
                return (app, s)
            }
            let sorted = scored.sorted { a, b in
                a.score != b.score ? a.score > b.score : a.app.sortKey < b.app.sortKey
            }
            results = sorted.prefix(Self.maxResults).map(\.app)
        }
        selection = q.isEmpty ? firstVisibleIndex() : 0
        if !q.isEmpty { showingIndex = false }
    }

    private func score(_ app: AppItem, _ q: String) -> Int? {
        var best: Int?
        func take(_ s: Int) { best = max(best ?? s, s) }
        for k in app.keywords {
            if k == q { take(1000) }
            else if k.hasPrefix(q) { take(800) }
            else if k.contains(q) { take(400) }
            else if isSubsequence(q, of: k) { take(150) }
        }
        if app.words.contains(where: { $0.hasPrefix(q) }) { take(700) }
        return best
    }

    private func isSubsequence(_ q: String, of s: String) -> Bool {
        var it = s.makeIterator()
        return q.allSatisfy { c in
            while let n = it.next() { if n == c { return true } }
            return false
        }
    }
}
