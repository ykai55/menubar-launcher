import AppKit
import SwiftUI

/// 浏览网格摊平后的一项：分组标题或一行图标。id 全局唯一，供 LazyVStack 复用和记录滚动位置
struct GridEntry: Identifiable {
    enum Kind {
        case header(String)
        case divider
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

    var height: CGFloat {
        switch kind {
        case .header, .back: return Layout.headerHeight
        case .divider: return Layout.dividerHeight
        case .row: return Layout.cellHeight
        }
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

    var isFolder: Bool { if case .folder = self { true } else { false } }
}

/// 浏览网格的两种排法：定制模式按配置的目录和顺序组织，可以拖动调整；顺序模式把所有应用按首字母排开
enum BrowseMode: String {
    case custom, sorted

    func title(_ language: AppLanguage) -> String {
        self == .custom ? language.text("Custom", "定制") : language.text("A–Z", "顺序")
    }
    var other: BrowseMode { self == .custom ? .sorted : .custom }
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

    @Published var query = "" { didSet { cancelDrag(); refilter() } }
    /// 搜索模式下的结果
    @Published private(set) var results: [AppItem] = []
    /// 浏览模式（空查询）下的全部格子，按显示顺序
    @Published private(set) var browseItems: [Tile] = []
    /// 和 browseItems 一一对应：每格所属分组的 key，拖动只能在同一分组内进行
    private var tileGroups: [String] = []
    @Published private(set) var entries: [GridEntry] = []
    /// 来自 ~/.config/menulauncher/config.json，外部修改后自动重新读取
    @Published private(set) var config = LauncherConfig()
    /// 配置文件读不出来时的错误，沿用上一次读到的配置
    @Published private(set) var configError: String?
    @Published var failedShortcuts: [String] = []
    var language: AppLanguage { config.language ?? .system }
    /// 当前打开的目录（配置里的下标路径），空表示在顶层
    @Published private(set) var folderPath: [Int] = []
    @Published private(set) var showingHidden = false
    private var hiddenRootPath: [Int]?
    @Published var selection = 0
    /// 用户选过的模式；没选过时有目录就用定制模式，否则用顺序模式
    @Published private var chosenMode = UserDefaults.standard.string(forKey: "browseMode").flatMap(BrowseMode.init)
    var mode: BrowseMode { chosenMode ?? (config.folders.isEmpty ? .sorted : .custom) }
    /// 当前模式顶层网格的滚动偏移（像素），两种模式各存一份，跨次打开（包括重启）保持滚动位置。
    /// 故意不用 @Published：滚动时它会频繁变化，发布出去会让整个面板跟着重绘
    var scrollOffset: CGFloat {
        get { UserDefaults.standard.double(forKey: "scrollOffset.\(mode.rawValue)") }
        set { UserDefaults.standard.set(Double(newValue), forKey: "scrollOffset.\(mode.rawValue)") }
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
    var canGoBack: Bool { inFolder || showingHidden }
    var canShowIndex: Bool { mode == .sorted && !showingHidden && !inFolder }

    /// 当前目录的名字路径，例如 ["开发", "数据库"]
    var folderNames: [String] {
        folderPath.indices.compactMap { config.folder(at: Array(folderPath[...$0]))?.name }
    }

    /// 区分两种模式的顶层和各个目录，视图据此给每一层一个独立的滚动视图
    var levelKey: String {
        (showingHidden ? "hidden:" : "") + mode.rawValue + ":" + folderPath.map(String.init).joined(separator: ".")
    }

    func setShowingHidden(_ hidden: Bool) {
        cancelDrag()
        query = ""
        showingHidden = hidden
        hiddenRootPath = nil
        folderPath = []
        showingIndex = false
        rebuildBrowse()
        refilter()
    }

    /// 切换定制 / 顺序模式。在目录里时先回到顶层
    func setMode(_ m: BrowseMode) {
        guard m != mode else { return }
        cancelDrag()
        chosenMode = m
        UserDefaults.standard.set(m.rawValue, forKey: "browseMode")
        showingHidden = false
        hiddenRootPath = nil
        folderPath = []
        showingIndex = false
        rebuildBrowse()
        selection = firstVisibleIndex()
    }

    func openFolder(_ path: [Int]) {
        guard config.folder(at: path) != nil else { return }
        guard showingHidden || !config.isFolderHidden(at: path) else { return }
        cancelDrag()
        if showingHidden && !inFolder { hiddenRootPath = path }
        folderPath = path
        rebuildBrowse()
        selection = 0
    }

    /// 回到上一级目录；已在顶层时返回 false
    @discardableResult
    func leaveFolder() -> Bool {
        guard canGoBack else { return false }
        cancelDrag()
        if !inFolder {
            setShowingHidden(false)
            return true
        }
        if showingHidden && folderPath == hiddenRootPath {
            folderPath = []
            hiddenRootPath = nil
        } else { folderPath.removeLast() }
        rebuildBrowse()
        selection = inFolder ? 0 : firstVisibleIndex()
        return true
    }

    /// 跳到某个分组：标题贴顶，选中该组第一个应用
    func jump(to title: String) {
        showingIndex = false
        guard canShowIndex else { return }
        guard let h = entries.firstIndex(where: { $0.id == "h:\(title)" }) else { return }
        if let first = entries[h...].lazy.compactMap(\.indices.first).first { selection = first }
        scrollRequest = ScrollRequest(rowID: entries[h].id, anchor: .top, token: (scrollRequest?.token ?? 0) + 1)
    }

    var onLaunched: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    func savePreferences(_ draft: PreferencesDraft, baseline: PreferencesDraft) throws {
        cancelDrag()
        let latest = try ConfigStore.load() ?? LauncherConfig()
        let updated = try draft.merging(into: latest, baseline: baseline)
        try ConfigStore.save(updated)
        config = updated
        configDate = ConfigStore.modificationDate
        configError = nil
        applyConfig()
    }

    private var apps: [AppItem] = []
    /// 去掉隐藏应用之后的，网格和搜索都只用它
    private var shownApps: [AppItem] = []
    private var lastScan = Date.distantPast
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var configDate: Date?

    var isBrowsing: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }
    var visibleCount: Int { isBrowsing ? browseItems.count : results.count }

    /// 浏览网格的高度，始终按顶层内容算：进目录时面板不跟着变矮，和顶层保持一样高
    private var browseHeight: CGFloat = Layout.gridHeight(headers: 0, rows: 0)

    var preferredHeight: CGFloat {
        let banner = configError == nil ? 0 : Layout.errorHeight
        if isBrowsing { return banner + browseHeight }
        return banner + Layout.listHeight(rows: max(results.count, 1))
    }

    func reload(apps scanned: [AppItem]? = nil) {
        cancelDrag()
        apps = scanned ?? AppIndex.scan()
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
            configError = ConfigStore.describe(error, language: language)
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
        cancelDrag()
        loadConfig()
        applyConfig()
    }

    /// 配置变了（或重扫了应用）之后重算隐藏、固定、目录
    private func applyConfig() {
        let selectedKey = isBrowsing && browseItems.indices.contains(selection) ? tileKey(selection) : nil
        let selectedResult = !isBrowsing && results.indices.contains(selection) ? results[selection].id : nil
        UsageLog.enabled = config.recordUsage ?? true
        let hiddenRefs = config.hidden + config.hiddenFolderAppRefs
        shownApps = apps.filter { app in !hiddenRefs.contains(where: app.matches) }
        if config.folder(at: folderPath) == nil { folderPath = [] }
        if !showingHidden && config.isFolderHidden(at: folderPath) { folderPath = [] }
        if showingHidden, let root = hiddenRootPath, !config.isFolderHidden(at: root) {
            folderPath = []
            hiddenRootPath = nil
        }
        rebuildBrowse()
        refilter(resetSelection: false)
        if isBrowsing {
            selection = selectedKey.flatMap { key in browseItems.indices.first { tileKey($0) == key } }
                ?? firstVisibleIndex()
        } else {
            selection = selectedResult.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
        }
    }

    /// 从界面改配置：改完立即生效并写回文件
    private func updateConfig(_ change: (inout LauncherConfig) -> Void) {
        change(&config)
        do {
            try ConfigStore.save(config)
            configError = nil
        } catch {
            configError = language.text("Could not save settings: ", "保存配置失败：") + error.localizedDescription
        }
        configDate = ConfigStore.modificationDate
        applyConfig()
        selection = min(selection, max(visibleCount - 1, 0))
    }

    private func resolve(_ refs: [String], includeHidden: Bool = false) -> [AppItem] {
        var seen = Set<String>()
        let source = includeHidden ? apps : shownApps
        return refs.compactMap { ref in source.first(where: { $0.matches(ref) }) }
            .filter { seen.insert($0.id).inserted }
    }

    /// 距上次扫描超过 5 分钟就重扫，用来发现新装/卸载的应用
    func reloadIfStale() {
        if Date().timeIntervalSince(lastScan) > 300 { reload() }
    }

    /// 面板隐藏后调用：清掉搜索和索引层，让网格在看不见的时候就恢复好，下次打开直接显示
    func resetAfterHide() {
        cancelDrag()
        query = ""
        showingIndex = false
        if canGoBack {
            showingHidden = false
            hiddenRootPath = nil
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
        guard !inFolder && !showingHidden else { return 0 }
        var y = Layout.padding
        for e in entries {
            let h = e.height
            if let first = e.indices.first, y >= scrollOffset - 1 { return first }
            y += h
        }
        return 0
    }

    /// 保存的偏移落在哪一项上（取离得近的边界），恢复时按项对齐，不会停在半行
    func entryIDForSavedOffset() -> String? {
        var y = Layout.padding
        for e in entries {
            let h = e.height
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
        updateConfig { c in
            if !c.hidden.contains(where: app.matches) { c.hidden.append(app.configRef) }
        }
    }

    func unhide(_ app: AppItem) {
        updateConfig { $0.hidden.removeAll(where: app.matches) }
    }

    func setFolderHidden(_ path: [Int], _ hidden: Bool) {
        cancelDrag()
        updateConfig { $0.editFolder(at: path) { $0.hidden = hidden } }
    }

    /// 从当前打开的目录里移出，回到「应用」分组
    func removeFromFolder(_ app: AppItem) {
        let path = folderPath
        updateConfig { c in c.editFolder(at: path) { $0.apps.removeAll(where: app.matches) } }
    }

    // MARK: - 拖动排序（定制模式）

    var canReorder: Bool { mode == .custom && isBrowsing && !showingHidden }
    /// 正在拖动的格子当前所在的下标。拖动过程中只在内存里调整 browseItems，松手时才写回配置
    @Published private(set) var dragIndex: Int?
    /// 被拖格子左上角在网格里的位置，跟着鼠标走
    @Published private(set) var dragOrigin: CGPoint = .zero
    /// 按下时鼠标相对格子左上角的位置
    private var grab: CGSize = .zero
    /// 拖到网格外松手（取消）时恢复成这个顺序
    private var dragSnapshot: [Tile] = []
    /// 中央停留 0.4 秒移入；边缘显示插入线，短暂停留或松手排序。
    @Published private(set) var folderDropTarget: Int?
    private var folderHover: (index: Int, since: TimeInterval)?
    static let folderDropDelay: TimeInterval = 0.4
    struct FolderInsertion: Equatable {
        let index: Int
        let after: Bool
    }
    @Published private(set) var folderInsertion: FolderInsertion?
    private var insertionSince: TimeInterval = 0
    static let folderInsertionDelay: TimeInterval = 0.18

    /// 当前层滚动视图的偏移和可视高度，视图滚动时写入。只给拖动时自动滚动用，不发布
    var viewportOffset: CGFloat = 0
    var viewportHeight: CGFloat = 0
    /// 网格中的 AppKit 探针，只弱引用；滚动时以 NSClipView 的实际偏移为准。
    weak var dragSurface: NSView?
    private var autoScrollTimer: Timer?
    /// 最近一次拖动的鼠标位置和网格几何。内容滚动后鼠标没动也要按新位置重新判断换位
    private var lastDrag: (location: CGPoint, geo: GridGeometry, offset: CGFloat)?

    /// 格子的视图 id。同一个应用可能同时出现在「固定」和别的分组里，所以带上分组
    func tileKey(_ i: Int) -> String { tileGroups[i] + "|" + browseItems[i].id }

    /// 拖动中鼠标移到 location（网格坐标）。不用系统拖放：系统的拖动图像松手后还会停留几帧，
    /// 和落位的格子叠成两个；这里格子本身跟着鼠标走，从头到尾只有一个
    func drag(_ i: Int, start: CGPoint, location: CGPoint, geo: GridGeometry) {
        guard canReorder else { return }
        if dragIndex == nil {
            guard browseItems.indices.contains(i) else { return }
            dragSnapshot = browseItems
            let o = geo.origins[i]
            grab = CGSize(width: start.x - o.x, height: start.y - o.y)
            dragIndex = i
            selection = i
            startAutoScroll()
        }
        guard let from = dragIndex else { return }
        let offset = dragSurface?.enclosingScrollView?.contentView.bounds.minY ?? viewportOffset
        lastDrag = (location, geo, offset)
        dragOrigin = CGPoint(x: location.x - grab.width, y: location.y - grab.height)
        // 按图标中心找目标格，并且要进到格子中间一圈才换位：按鼠标算时，鼠标停在行与行交界处，
        // 目标会在上下两行之间来回跳，整排图标被反复挤来挤去
        let center = CGPoint(x: dragOrigin.x + Layout.cellWidth / 2, y: dragOrigin.y + Layout.cellHeight / 2)
        if let to = folderCandidate(at: location, from: from, geo: geo) {
            let origin = geo.origins[to]
            let x = location.x - origin.x, y = location.y - origin.y
            let central = x >= Layout.cellWidth * 0.25 && x <= Layout.cellWidth * 0.75
                && y >= Layout.cellHeight * 0.2 && y <= Layout.cellHeight * 0.8
            if central {
                clearFolderInsertion()
                if folderHover?.index != to {
                    folderHover = (to, ProcessInfo.processInfo.systemUptime)
                    folderDropTarget = nil
                }
                updateFolderDropReadiness()
            } else {
                clearFolderDrop()
                if tileGroups[from] == tileGroups[to] {
                    let after = y < Layout.cellHeight * 0.2 ? false :
                        (y > Layout.cellHeight * 0.8 ? true : x > Layout.cellWidth / 2)
                    let insertion = FolderInsertion(index: to, after: after)
                    if folderInsertion != insertion {
                        folderInsertion = insertion
                        insertionSince = ProcessInfo.processInfo.systemUptime
                    }
                    applyFolderInsertion()
                } else { clearFolderInsertion() }
            }
            return
        }
        clearFolderDrop()
        clearFolderInsertion()
        guard let to = geo.index(at: center, inset: 0.2), to != from,
              tileGroups.indices.contains(to), tileGroups[from] == tileGroups[to] else { return }
        // 图标中心可能比光标先到达目录。保留目标位置，等光标进入后开始计时，
        // 否则排序会先把目录挤开，正常的连续轨迹永远到不了停留区域。
        if canDropIntoFolder(to, from: from) { return }
        reorderDrag(from: from, to: to)
    }

    private func reorderDrag(from: Int, to: Int) {
        var items = browseItems
        items.insert(items.remove(at: from), at: to)
        withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
            browseItems = items
            dragIndex = to
            selection = to
        }
    }

    private func folderCandidate(at point: CGPoint, from: Int, geo: GridGeometry) -> Int? {
        guard let to = geo.index(at: point), canDropIntoFolder(to, from: from) else { return nil }
        let rect = CGRect(origin: geo.origins[to], size: CGSize(width: Layout.cellWidth, height: Layout.cellHeight))
        // 使用整个格子，确保连续接近时先锁住目录；不把行尾空白当作最后一格。
        return rect.contains(point) ? to : nil
    }

    private func canDropIntoFolder(_ to: Int, from: Int) -> Bool {
        guard to != from, browseItems.indices.contains(to), browseItems.indices.contains(from),
              case .folder(_, let target, _) = browseItems[to],
              !config.isFolderHidden(at: target) else { return false }
        if case .folder(_, let source, _) = browseItems[from],
           !config.canMoveFolder(source, into: target) { return false }
        return true
    }

    private func updateFolderDropReadiness() {
        guard let hover = folderHover, folderDropTarget == nil,
              ProcessInfo.processInfo.systemUptime - hover.since >= Self.folderDropDelay else { return }
        folderDropTarget = hover.index
    }

    private func clearFolderDrop() {
        folderHover = nil
        folderDropTarget = nil
    }

    private func clearFolderInsertion() {
        folderInsertion = nil
        insertionSince = 0
    }

    private func applyFolderInsertion(force: Bool = false) {
        guard let insertion = folderInsertion, let from = dragIndex,
              force || ProcessInfo.processInfo.systemUptime - insertionSince >= Self.folderInsertionDelay else { return }
        let to = insertion.index + (insertion.after ? 1 : 0) - (from < insertion.index ? 1 : 0)
        guard to != from else { return }
        clearFolderInsertion()
        reorderDrag(from: from, to: to)
    }

    /// 松手：落在网格里就移进当前空位并写回配置，落到网格外就取消，恢复原来的顺序
    func endDrag(location: CGPoint, inGrid: Bool) {
        // 以松手位置复核目标，不能把上一次 hover 当作最终落点。
        if inGrid, let i = dragIndex, let last = lastDrag {
            drag(i, start: .zero, location: location, geo: last.geo)
        }
        let target = folderDropTarget
        let quickTarget = folderHover?.index
        stopAutoScroll()
        if inGrid { applyFolderInsertion(force: true) }
        clearFolderInsertion()
        guard let i = dragIndex else { return }
        if inGrid, let target {
            moveDraggedTile(i, into: target)
            return
        }
        clearFolderDrop()
        // 中央短暂停留后立即松手仍视为排序；固定区到目录的移动必须等高亮。
        if inGrid, let quickTarget, tileGroups[i] == tileGroups[quickTarget] {
            reorderDrag(from: i, to: quickTarget)
        }
        guard let i = dragIndex else { return }
        let key = tileKey(i)
        if inGrid { commitOrder(group: tileGroups[i]) }
        withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
            if !inGrid { browseItems = dragSnapshot }
            dragIndex = nil
        }
        // 取消时也按身份找回原位；配置重建本身保持选中项，不再发布中间的首格高亮。
        selection = browseItems.indices.first { tileKey($0) == key } ?? selection
        dragSnapshot = []
    }

    private func moveDraggedTile(_ source: Int, into destination: Int) {
        guard case .folder(_, let target, _) = browseItems[destination] else { return }
        let tile = browseItems[source]
        clearFolderDrop()
        clearFolderInsertion()
        // 预览时的让位不写回；本次只提交目录移动，避免应用消失后残留下标。
        browseItems = dragSnapshot
        dragIndex = nil
        dragSnapshot = []
        var destinationPath = target
        updateConfig { config in
            switch tile {
            case .app(let app): config.moveApp(app, into: target)
            case .folder(_, let path, _):
                destinationPath = config.moveFolder(path, into: target) ?? target
            }
        }
        selection = browseItems.firstIndex {
            if case .folder(_, let path, _) = $0 { return path == destinationPath }
            return false
        } ?? min(selection, max(browseItems.count - 1, 0))
    }

    func cancelDrag() {
        endDrag(location: .zero, inGrid: false)
    }

    /// 拖到可视区域上下边缘附近时持续滚动，越靠边越快
    private func startAutoScroll() {
        autoScrollTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoScrollTick() }
        }
        // 拖动时 runloop 处在事件跟踪模式，默认模式的定时器不会触发
        RunLoop.main.add(t, forMode: .common)
        autoScrollTimer = t
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        lastDrag = nil
    }

    private func autoScrollTick() {
        updateFolderDropReadiness()
        applyFolderInsertion()
        guard let i = dragIndex, let last = lastDrag,
              let scroll = dragSurface?.enclosingScrollView else { return }
        let clip = scroll.contentView
        let before = clip.bounds.minY
        let height = clip.bounds.height
        guard height > 0 else { return }
        // 手动滚轮和自动滚动都可能改变偏移。保存鼠标相对可视区的位置，
        // 即使没有新的 DragGesture 事件，也能让图标留在鼠标下方。
        let location = CGPoint(x: last.location.x, y: last.location.y + before - last.offset)
        // 网格坐标在内边距里面，换算成滚动内容的坐标
        let y = location.y + Layout.padding - before
        let zone: CGFloat = 40, maxStep: CGFloat = 14
        var step: CGFloat = 0
        if location.x >= 0 && location.x <= Layout.width - Layout.padding * 2 {
            if y < zone { step = -maxStep * min((zone - y) / zone, 1) }
            else if y > height - zone { step = maxStep * min((y - height + zone) / zone, 1) }
        }
        let maxOffset = max(last.geo.height + Layout.padding * 2 - height, 0)
        let target = min(max(before + step, 0), maxOffset)
        if abs(target - before) >= 0.5 {
            clip.scroll(to: CGPoint(x: clip.bounds.minX, y: target))
            scroll.reflectScrolledClipView(clip)
        }
        let actual = clip.bounds.minY
        viewportOffset = actual
        viewportHeight = height
        guard abs(actual - last.offset) >= 0.01 else { return }
        drag(i, start: .zero,
             location: CGPoint(x: location.x, y: location.y + actual - before), geo: last.geo)
    }

    /// 目录在 order 里的写法
    static let folderRefPrefix = "folder:"

    /// 把某个分组当前的顺序写回配置：固定写 pinned，顶层写 order，目录里写目录的 order
    private func commitOrder(group: String) {
        let tiles = tileGroups.indices.filter { tileGroups[$0] == group }.map { browseItems[$0] }
        /// 按新顺序排出引用。已有引用保留写法，不可见项保留原来的槽位。
        func refs(_ old: [String]) -> [String] {
            let listed = tiles.map { t -> String in
                switch t {
                case .app(let a): return old.first(where: a.matches) ?? a.configRef
                case .folder(let name, _, _): return Self.folderRefPrefix + name
                }
            }
            // 不可见项保留原有槽位；恢复隐藏后仍回到原来的相对位置。
            let visible = Set(listed)
            var remaining = listed.makeIterator()
            var merged = old.map { visible.contains($0) ? (remaining.next() ?? $0) : $0 }
            while let ref = remaining.next() { merged.append(ref) }
            return merged
        }
        let path = folderPath
        updateConfig { c in
            switch group {
            case "固定": c.pinned = refs(c.pinned)
            case "应用": c.order = refs(c.order)
            default: c.editFolder(at: path) { $0.order = refs($0.order) }
            }
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
            if inFolder {
                UsageLog.launched(app, via: "folder", folder: folderNames.joined(separator: "/"))
            } else {
                let pinnedSection = entries.first { $0.indices.contains(i) }?.id.hasPrefix("r:固定:") == true
                UsageLog.launched(app, via: pinnedSection ? "pinned" : "grid")
            }
        } else {
            guard results.indices.contains(i) else { return }
            app = results[i]
            UsageLog.launched(app, via: "search", query: query.trimmingCharacters(in: .whitespaces))
        }

        let open = NSWorkspace.OpenConfiguration()
        open.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: open)
        onLaunched?()
    }

    // MARK: - 构建列表

    private func rebuildBrowse() {
        var items: [Tile] = []
        var groups: [String] = []
        var entries: [GridEntry] = []

        func addRows(_ key: String, _ group: [Tile]) {
            let start = items.count
            items += group
            groups += Array(repeating: key, count: group.count)
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
        /// 目录和应用混排：order 里列出的按 order 排；没列出的目录按 folders 顺序排在前面，没列出的应用按给定顺序排在后面
        func arrange(_ list: [FolderConfig], _ prefix: [Int], _ apps: [AppItem], _ order: [String],
                     includeHidden: Bool = false) -> [Tile] {
            var folders: [Tile?] = list.enumerated().map { i, f in
                guard includeHidden || !f.hidden else { return nil }
                return .folder(name: f.name, path: prefix + [i],
                               icons: resolve(f.apps, includeHidden: includeHidden).prefix(4).map(\.icon))
            }
            var rest: [AppItem?] = apps
            var out: [Tile] = []
            for ref in order {
                if ref.hasPrefix(Self.folderRefPrefix) {
                    let name = String(ref.dropFirst(Self.folderRefPrefix.count))
                    if let i = list.indices.first(where: { list[$0].name == name && folders[$0] != nil }) {
                        out.append(folders[i]!)
                        folders[i] = nil
                    }
                } else if let i = rest.firstIndex(where: { $0?.matches(ref) == true }) {
                    out.append(.app(rest[i]!))
                    rest[i] = nil
                }
            }
            // 没列出的目录排最前（和以前目录在前的排法一致，旧配置升级后位置不变），没列出的应用排最后
            return folders.compactMap { $0 } + out + rest.compactMap { $0.map(Tile.app) }
        }
        /// 排出某个模式的顶层，返回它的高度
        func buildTop(_ m: BrowseMode) -> CGFloat {
            items = []
            entries = []
            groups = []
            let pinned = resolve(config.pinned).map(Tile.app)
            switch m {
            case .custom:
                // 目录和没进任何目录的应用混排在同一组（固定的仍然出现在这里，固定只是快捷方式）。
                // 按 order 排，没列出的（新装的）按名字排在后面
                let filed = Set(config.allFolders().flatMap { resolve($0.folder.apps).map(\.id) })
                let unfiled = shownApps.filter { !filed.contains($0.id) }
                let main = arrange(config.folders, [], unfiled, config.order)
                addRows("固定", pinned)
                if !pinned.isEmpty && !main.isEmpty {
                    entries.append(GridEntry(id: "divider", kind: .divider))
                }
                addRows("应用", main)
            case .sorted:
                add("固定", pinned)
                // 全部应用按首字母分组，不管在不在目录里
                let byLetter = Dictionary(grouping: shownApps, by: \.section)
                for letter in byLetter.keys.sorted(by: { ($0 == "#" ? "~" : $0) < ($1 == "#" ? "~" : $1) }) {
                    add(letter, byLetter[letter]!.map(Tile.app))
                }
            }
            return Layout.searchHeight + 1 + min(entries.reduce(Layout.padding * 2) { $0 + $1.height },
                                                 Layout.maxGridHeight)
        }

        // 面板高度取两种模式顶层里高的那个：切模式、进目录时面板都不跟着变高变矮
        let otherHeight = buildTop(mode.other)
        browseHeight = max(buildTop(mode), otherHeight)

        if showingHidden {
            // 隐藏区保持可视高度，空目录也有明确的返回入口和空态。
            browseHeight = Layout.searchHeight + 1 + Layout.maxGridHeight
            items = []
            groups = []
            entries = [GridEntry(id: "b:hidden", kind: .back(language.text("Hidden items", "隐藏区")))]
            let roots = config.hiddenFolderRoots
            let folders: [Tile] = roots.map {
                .folder(name: $0.folder.name, path: $0.path,
                        icons: resolve($0.folder.apps, includeHidden: true).prefix(4).map(\.icon))
            }
            // 已属于隐藏目录的应用在目录内查看，避免隐藏区顶层重复列出。
            let filed = config.hiddenFolderAppRefs
            let looseApps = resolve(config.hidden, includeHidden: true).filter { app in
                !filed.contains(where: app.matches)
            }
            addRows("隐藏", folders + looseApps.map(Tile.app))
        }

        if inFolder, let folder = config.folder(at: folderPath) {
            // 目录内：返回条 + 子目录和应用混排，按目录的 order，没列出的子目录在前、应用按 apps 顺序
            items = []
            groups = []
            entries = [GridEntry(id: "b:\(levelKey)", kind: .back(folder.name))]
            addRows("f\(levelKey)", arrange(folder.folders, folderPath,
                resolve(folder.apps, includeHidden: showingHidden), folder.order, includeHidden: showingHidden))
        }

        browseItems = items
        tileGroups = groups
        self.entries = entries
    }

    private func refilter(resetSelection: Bool = true) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            results = []
        } else {
            // 只按匹配程度排序，不掺使用频率，同一个查询结果顺序始终一致
            let source = showingHidden ? apps.filter { config.isHidden($0) } : shownApps
            let scored: [(app: AppItem, score: Int)] = source.compactMap { app in
                guard let s = score(app, q) else { return nil }
                return (app, s)
            }
            let sorted = scored.sorted { a, b in
                a.score != b.score ? a.score > b.score : a.app.sortKey < b.app.sortKey
            }
            results = sorted.prefix(Self.maxResults).map(\.app)
        }
        if resetSelection { selection = q.isEmpty ? firstVisibleIndex() : 0 }
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
