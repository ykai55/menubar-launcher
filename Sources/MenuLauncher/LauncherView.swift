import SwiftUI

enum Layout {
    static let width: CGFloat = 480
    static let searchHeight: CGFloat = 40
    static let rowHeight: CGFloat = 30
    static let padding: CGFloat = 6

    static let columns = 6
    static let cellWidth: CGFloat = (width - padding * 2) / CGFloat(columns)
    static let cellHeight: CGFloat = 88
    static let labelHeight: CGFloat = 28
    /// 上方 8 + 胶囊 22 + 下方 8 的间隙
    static let headerHeight: CGFloat = 38
    static let maxGridHeight: CGFloat = 520

    static let errorHeight: CGFloat = 32

    static func listHeight(rows: Int) -> CGFloat {
        searchHeight + 1 + CGFloat(rows) * rowHeight + padding * 2
    }

    static func gridHeight(headers: Int, rows: Int) -> CGFloat {
        let content = padding * 2 + CGFloat(headers) * headerHeight + CGFloat(rows) * cellHeight
        return searchHeight + 1 + min(content, maxGridHeight)
    }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索应用", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
            }
            .padding(.horizontal, 12)
            .frame(height: Layout.searchHeight)

            Divider()

            if let error = model.configError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: Layout.errorHeight, alignment: .leading)
                    .help(error)
            }

            if model.isBrowsing {
                grid
            } else {
                list
            }
        }
        .frame(width: Layout.width, alignment: .top)
        .onAppear { focused = true }
        .onChange(of: model.showToken) { focused = true }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 摊平成一层：每个分组标题、每行图标都是固定高度、id 唯一的子项。
                // 之前嵌套 ForEach 用 offset 作 id，各分组之间重复，LazyVStack 复用视图时会错位
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.entries) { entry in
                        switch entry.kind {
                        case .header(let title):
                            SectionHeader(title: title) { model.showingIndex = true }
                        case .back(let name):
                            BackBar(name: name) { model.leaveFolder() }
                        case .row(let indices):
                            HStack(spacing: 0) {
                                ForEach(indices, id: \.self) { cell($0) }
                                Spacer(minLength: 0)
                            }
                            .frame(height: Layout.cellHeight)
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(Layout.padding)
            }
            .scrollIndicators(.never)
            // 只读地记录像素偏移。滚动只通过 proxy.scrollTo 主动触发，不绑定 scrollPosition：
            // 绑定的值不会随手动滚动/跳转更新，视图一刷新（比如 hover 改选中项）就会把列表拉回那个旧位置
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in
                if model.isBrowsing && !model.showingIndex && !model.inFolder { model.scrollOffset = max(y, 0) }
            }
            // 每一层目录各用一个滚动视图：进目录从顶部开始，退回顶层时重新出现，按保存的偏移恢复
            .id(model.levelKey)
            // 滚动视图常驻，隐藏再打开时位置本来就还在，只在网格重新出现（启动、从搜索切回、退出目录）时恢复
            .onAppear { if !model.inFolder { restoreScroll(proxy) } }
            .onChange(of: model.scrollRequest) {
                guard let r = model.scrollRequest else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(r.rowID, anchor: r.anchor) }
            }
            // 索引层常驻，只切换透明度和命中测试。按需插入/移除时，移除后 ScrollView 的鼠标跟踪不会立即恢复，
            // 要再点一下才能滚动
            .overlay {
                LetterIndex(available: Set(model.sectionTitles),
                            onPick: { model.jump(to: $0) },
                            onDismiss: { model.showingIndex = false })
                    .opacity(model.showingIndex ? 1 : 0)
                    .allowsHitTesting(model.showingIndex)
            }
            .animation(.easeOut(duration: 0.12), value: model.showingIndex)
        }
    }

    private func restoreScroll(_ proxy: ScrollViewProxy) {
        guard let id = model.entryIDForSavedOffset() else { return }
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
    }

    /// 滚轮滚动时，格子从静止的光标下滑过也会触发 hover，这时忽略。
    /// 否则每滚过一格都改 selection，整个面板跟着重算，滚动就卡
    private func hoverSelect(_ i: Int) {
        guard NSApp.currentEvent?.type != .scrollWheel, model.selection != i else { return }
        model.selection = i
    }

    private func cell(_ i: Int) -> some View {
        let tile = model.browseItems[i]
        return GridCell(tile: tile, selected: i == model.selection)
            .equatable()
            .onHover { if $0 { hoverSelect(i) } }
            .onTapGesture { model.launch(at: i) }
            .contextMenu {
                if case .app(let app) = tile { menu(for: app) }
                else { Button("编辑配置文件…") { model.openConfig() } }
            }
    }

    private var list: some View {
        VStack(spacing: 0) {
            if model.results.isEmpty {
                Text("没有匹配的应用")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Layout.rowHeight)
            }
            ForEach(Array(model.results.enumerated()), id: \.element.id) { i, app in
                Row(app: app, selected: i == model.selection)
                    .onHover { if $0 { hoverSelect(i) } }
                    .onTapGesture { model.launch(at: i) }
                    .contextMenu { menu(for: app) }
            }
        }
        .padding(Layout.padding)
    }

    @ViewBuilder
    private func menu(for app: AppItem) -> some View {
        Button(model.isPinned(app) ? "取消固定" : "固定到顶部") { model.togglePin(app) }
        if model.inFolder && model.isBrowsing {
            Button("移出目录") { model.removeFromFolder(app) }
        }
        Button("隐藏") { model.hide(app) }
        Divider()
        Button("在 Finder 中显示") { model.revealInFinder(app) }
    }
}

/// 网格里的分组标题，做成可点的小胶囊：hover 高亮，点击打开字母索引。
/// 胶囊和下方图标之间留出间隙，避免误点到应用
private struct SectionHeader: View {
    let title: String
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(hovered ? Color.white : Color.secondary)
            .padding(.horizontal, 10)
            .frame(minWidth: 28, minHeight: 22)
            .background(
                Capsule().fill(hovered ? Color.accentColor : Color.primary.opacity(0.06))
            )
            .contentShape(Capsule())
            .onHover { inside in
                // 滚轮滚过时不高亮，和网格格子的处理一致
                hovered = inside && NSApp.currentEvent?.type != .scrollWheel
            }
            .onTapGesture(perform: onTap)
            .help("点击选择首字母")
            .padding(.leading, 4)
            .padding(.top, 8)
            .padding(.bottom, Layout.headerHeight - 22 - 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Layout.headerHeight)
    }
}

/// 目录顶部的返回条：点击或按 Esc / ⌫ 回到上一级
private struct BackBar: View {
    let name: String
    let onBack: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left")
                .font(.system(size: 11, weight: .semibold))
            Text(name)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(hovered ? Color.white : Color.secondary)
        .padding(.horizontal, 10)
        .frame(minHeight: 22)
        .background(Capsule().fill(hovered ? Color.accentColor : Color.primary.opacity(0.06)))
        .contentShape(Capsule())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onBack)
        .help("返回上一级")
        .padding(.leading, 4)
        .padding(.top, 8)
        .padding(.bottom, Layout.headerHeight - 22 - 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Layout.headerHeight)
    }
}

/// 首字母索引：固定位置排出 固定 / A–Z / #，没有应用的字母置灰，位置不随应用增减变化
private struct LetterIndex: View {
    static let letters = ["固定", "目录"] + (65...90).map { String(UnicodeScalar($0)!) } + ["#"]

    let available: Set<String>
    let onPick: (String) -> Void
    let onDismiss: () -> Void

    @State private var hovered: String?

    private let columns = Array(repeating: GridItem(.fixed(56), spacing: 8), count: 7)

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Self.letters, id: \.self) { letter in
                    let enabled = available.contains(letter)
                    let isHovered = enabled && hovered == letter
                    Text(letter)
                        .font(.system(size: letter.count > 1 ? 15 : 22, weight: .semibold))
                        .frame(width: 56, height: 48)
                        .foregroundStyle(isHovered ? Color.white
                                         : enabled ? Color.primary : Color.secondary.opacity(0.35))
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(isHovered ? Color.accentColor
                                      : enabled ? Color.primary.opacity(0.08) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { hovered = letter } else if hovered == letter { hovered = nil }
                        }
                        .onTapGesture { if enabled { onPick(letter) } }
                }
            }
        }
    }
}

/// Equatable：选中项变化时只重绘新旧两个格子，其他格子跳过
private struct GridCell: View, Equatable {
    let tile: Tile
    let selected: Bool

    static func == (a: GridCell, b: GridCell) -> Bool {
        a.tile.id == b.tile.id && a.selected == b.selected && a.name == b.name
    }

    private var name: String {
        switch tile {
        case .app(let a): return a.name
        case .folder(let n, _, _): return n
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            switch tile {
            case .app(let app):
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 40, height: 40)
            case .folder(_, _, let icons):
                FolderIcon(icons: icons)
            }
            // 最多两行，固定占两行高度，单行名字顶部对齐，同一行图标保持齐平
            Text(name)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.tail)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 4)
                .frame(height: Layout.labelHeight, alignment: .top)
        }
        .padding(.top, 6)
        .frame(width: Layout.cellWidth - 4, height: Layout.cellHeight - 4, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        .frame(width: Layout.cellWidth, height: Layout.cellHeight)
        .contentShape(Rectangle())
        .help(name)
    }
}

/// 目录图标：圆角底板上排 2×2 个应用小图标，和 Launchpad 的文件夹类似；空目录显示文件夹符号
private struct FolderIcon: View {
    let icons: [NSImage]

    var body: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(Color.primary.opacity(0.12))
            .frame(width: 40, height: 40)
            .overlay {
                if icons.isEmpty {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.fixed(15), spacing: 3), GridItem(.fixed(15), spacing: 3)], spacing: 3) {
                        ForEach(icons.indices, id: \.self) { i in
                            Image(nsImage: icons[i]).resizable().frame(width: 15, height: 15)
                        }
                    }
                    .frame(width: 33, height: 33, alignment: .topLeading)
                }
            }
    }
}

private struct Row: View {
    let app: AppItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 20, height: 20)
            Text(app.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: Layout.rowHeight)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
