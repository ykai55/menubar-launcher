import SwiftUI

enum Layout {
    static let width: CGFloat = 480
    static let searchHeight: CGFloat = 40
    static let rowHeight: CGFloat = 30
    static let padding: CGFloat = 6

    static let columns = 6
    static let cellWidth: CGFloat = (width - padding * 2) / CGFloat(columns)
    static let cellHeight: CGFloat = 88
    /// 上方 8 + 胶囊 22 + 下方 8 的间隙
    static let headerHeight: CGFloat = 38
    static let dividerHeight: CGFloat = 13
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
                TextField(model.showingHidden ? model.language.text("Search hidden apps", "搜索隐藏应用") : model.language.text("Search apps", "搜索应用"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                Button { model.setShowingHidden(!model.showingHidden) } label: {
                    Image(systemName: model.showingHidden ? "eye.slash.fill" : "eye.slash")
                        .foregroundStyle(model.showingHidden ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(model.showingHidden ? model.language.text("Leave hidden items", "退出隐藏区") : model.language.text("Show hidden items", "进入隐藏区"))
                .accessibilityLabel(model.language.text("Hidden items", "隐藏区"))
                Button { model.onOpenSettings?() } label: {
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).focusable(false)
                .help(model.language.text("Settings… (⌘,)", "设置…（⌘,）"))
                .accessibilityLabel(model.language.text("Settings", "设置"))
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
        .environment(\.launcherLanguage, model.language)
        .onAppear { focused = true }
        .onChange(of: model.showToken) { focused = true }
    }

    private var grid: some View {
        // 这一层的 key。过渡期间正在淡出的旧层还活着，它的滚动回调不能写到新层的偏移里
        let level = model.levelKey
        return ScrollViewReader { proxy in
          // 外面套一层 ZStack，换层时新旧两个滚动视图能同时存在，做交叉过渡
          ZStack {
           GeometryReader { viewport in
            ScrollView {
              VStack(spacing: 0) {
                // 内容最顶端（含上边距）的锚点，恢复到第一项时滚到这里，不会把上边距滚出去
                Color.clear.frame(height: 0).id(Self.topAnchor)
                // 摊平成一层：每个分组标题、每行都是固定高度、id 唯一的子项，供滚动定位。
                // 行只占位，格子全部放在上面同一层里按坐标摆：拖动让位时每个图标只是换位置，
                // 跨行也是同一个视图滑过去。分行放在各自 HStack 里时，跨行等于旧行删一个、新行插一个，会同时看到两个
                let geo = GridGeometry(entries: model.entries, count: model.browseItems.count)
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.entries) { entry in
                            switch entry.kind {
                            case .header(let title):
                                SectionHeader(title: title) {
                                    if model.canShowIndex { model.showingIndex = true }
                                }.id(entry.id)
                            case .divider:
                                Divider().padding(.horizontal, 4)
                                    .frame(height: Layout.dividerHeight).id(entry.id)
                            case .back(let name):
                                BackBar(name: name) { model.leaveFolder() }.id(entry.id)
                            case .row:
                                Color.clear.frame(height: Layout.cellHeight).id(entry.id)
                            }
                        }
                    }
                    ForEach(model.browseItems.indices.map { ($0, model.tileKey($0)) }, id: \.1) { i, _ in
                        cell(i, geo: geo)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .coordinateSpace(.named(Self.gridSpace))
                .scrollTargetLayout()
                .background { DragScrollSurface(model: model, level: level) }
                .padding(Layout.padding)
              }
              // 短目录也覆盖整个可视区，否则下方点击会被 NSScrollView 吃掉，
              // 放在滚动视图背后的 background 手势收不到这些事件。
              .frame(minHeight: viewport.size.height, alignment: .top)
              .overlay(alignment: .top) {
                  if model.showingHidden && model.browseItems.isEmpty {
                      Text(model.inFolder ? model.language.text("This folder is empty", "此目录为空") : model.language.text("No hidden apps or folders", "没有隐藏的应用或目录"))
                          .font(.system(size: 13)).foregroundStyle(.secondary)
                          .padding(.top, Layout.headerHeight + 40)
                          .allowsHitTesting(false)
                  }
              }
              .contentShape(Rectangle())
              .onTapGesture {
                  // 子项的导航已切换层级时不再返回，避免一次点击进目录又退出。
                  if level == model.levelKey && model.canGoBack && model.dragIndex == nil {
                      model.leaveFolder()
                  }
              }
            }
            .scrollIndicators(.never)
            // 网格不参与键盘焦点：换层时新的滚动视图插进来，焦点系统会重新走一遍，
            // 搜索框失焦再聚焦，光标闪烁重新计时，看起来像突然快闪了一下
            .focusable(false)
            .focusEffectDisabled()
            // 只读地记录像素偏移。滚动只通过 proxy.scrollTo 主动触发，不绑定 scrollPosition：
            // 绑定的值不会随手动滚动/跳转更新，视图一刷新（比如 hover 改选中项）就会把列表拉回那个旧位置
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in
                if level == model.levelKey && model.isBrowsing && !model.showingIndex &&
                    !model.inFolder && !model.showingHidden {
                    model.scrollOffset = max(y, 0)
                }
            }
            .onScrollGeometryChange(for: CGRect.self, of: { $0.visibleRect }) { _, r in
                guard level == model.levelKey else { return }
                model.viewportOffset = r.minY
                model.viewportHeight = r.height
            }
            // 滚动视图常驻，隐藏再打开时位置本来就还在，只在网格重新出现（启动、从搜索切回、退出目录）时恢复
            .onAppear { if !model.inFolder && !model.showingHidden { restoreScroll(proxy) } }
            .onChange(of: model.scrollRequest) {
                guard let r = model.scrollRequest else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(r.rowID, anchor: r.anchor) }
            }
            // 索引层常驻，只切换透明度和命中测试。按需插入/移除时，移除后 ScrollView 的鼠标跟踪不会立即恢复，
            // 要再点一下才能滚动
            .overlay {
                LetterIndex(letters: LetterIndex.letters(for: model.mode),
                            available: Set(model.sectionTitles),
                            onPick: { model.jump(to: $0) },
                            onDismiss: { model.showingIndex = false })
                    .opacity(model.showingIndex && model.canShowIndex ? 1 : 0)
                    .scaleEffect(model.showingIndex ? 1 : 0.97)
                    .allowsHitTesting(model.showingIndex && model.canShowIndex)
            }
            .animation(.easeOut(duration: 0.15), value: model.showingIndex)
            // 每一层目录、每种模式各用一个滚动视图：进目录从顶部开始，退回顶层时重新出现，按保存的偏移恢复。
            // 换层时新旧两层交叉淡入淡出
            .id(model.levelKey)
            .transition(levelTransition)
           }
          }
        }
        .animation(.easeOut(duration: 0.18), value: model.levelKey)
        .clipped()
    }

    /// 新的一层从略小放大淡入，旧的一层直接淡出。以顶边为缩放中心，列表顶端始终贴着搜索框，不会上下漂
    private var levelTransition: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)), removal: .opacity)
    }

    private static let topAnchor = "top"

    private func restoreScroll(_ proxy: ScrollViewProxy) {
        guard let id = model.entryIDForSavedOffset() else { return }
        // 第一项就滚到最顶端；直接 scrollTo 第一项会把上边距也滚出去，列表看起来往上错了几个像素
        let target = id == model.entries.first?.id ? Self.topAnchor : id
        // 不带动画：恢复发生在换层过渡里，带上过渡的动画会让列表滑一下再停住
        DispatchQueue.main.async {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { proxy.scrollTo(target, anchor: .top) }
        }
    }

    private static let gridSpace = "grid"

    private func cell(_ i: Int, geo: GridGeometry) -> some View {
        let tile = model.browseItems[i]
        return SelectedGridCell(tile: tile, index: i, selection: model.selectionState)
            .onTapGesture { model.launch(at: i) }
            .contextMenu {
                if case .app(let app) = tile { menu(for: app) }
                else if case .folder(_, let path, _) = tile {
                    if model.config.folder(at: path)?.hidden == true {
                        Button(model.language.text("Unhide folder", "取消隐藏目录")) { model.setFolderHidden(path, false) }
                    } else if !model.showingHidden {
                        Button(model.language.text("Hide folder", "隐藏目录")) { model.setFolderHidden(path, true) }
                    }
                    Button(model.language.text("Edit config…", "编辑配置文件…")) { model.openConfig() }
                }
            }
            .overlay {
                if let insertion = model.folderInsertion, insertion.index == i {
                    HStack {
                        if insertion.after { Spacer(minLength: 0) }
                        Capsule().fill(Color.accentColor).frame(width: 3)
                        if !insertion.after { Spacer(minLength: 0) }
                    }
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
                }
            }
            .modifier(Reorderable(model: model, index: i, geo: geo, space: Self.gridSpace))
    }

    private var list: some View {
        VStack(spacing: 0) {
            if model.results.isEmpty {
                Text(model.language.text("No matching apps", "没有匹配的应用"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Layout.rowHeight)
            }
            ForEach(Array(model.results.enumerated()), id: \.element.id) { i, app in
                SelectedRow(app: app, index: i, selection: model.selectionState)
                    .onTapGesture { model.launch(at: i) }
                    .contextMenu { menu(for: app) }
            }
        }
        .padding(Layout.padding)
    }

    @ViewBuilder
    private func menu(for app: AppItem) -> some View {
        Button(model.isPinned(app) ? model.language.text("Unpin", "取消固定") : model.language.text("Pin to top", "固定到顶部")) { model.togglePin(app) }
        if model.inFolder && model.isBrowsing {
            Button(model.language.text("Remove from folder", "移出目录")) { model.removeFromFolder(app) }
        }
        if model.config.hidden.contains(where: app.matches) {
            Button(model.language.text("Unhide", "取消隐藏")) { model.unhide(app) }
        } else if model.showingHidden {
            Text(model.language.text("Hidden with its folder", "随所在目录隐藏"))
        } else {
            Button(model.language.text("Hide", "隐藏")) { model.hide(app) }
        }
        Divider()
        Button(model.language.text("Show in Finder", "在 Finder 中显示")) { model.revealInFinder(app) }
    }
}

/// 放在滚动内容内，只用于取得它实际所属的 NSScrollView，不参与点击和焦点。
private struct DragScrollSurface: NSViewRepresentable {
    let model: LauncherModel
    let level: String

    final class Surface: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Surface {
        let view = Surface()
        if level == model.levelKey { model.dragSurface = view }
        return view
    }

    func updateNSView(_ view: Surface, context: Context) {
        if level == model.levelKey { model.dragSurface = view }
    }
}

/// 网格里的分组标题，做成可点的小胶囊：hover 高亮，点击打开字母索引。
/// 胶囊和下方图标之间留出间隙，避免误点到应用
private struct SectionHeader: View {
    @Environment(\.launcherLanguage) private var language
    let title: String
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Text(language.section(title))
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
            .help(language.text("Choose a letter", "点击选择首字母"))
            .padding(.leading, 4)
            .padding(.top, 8)
            .padding(.bottom, Layout.headerHeight - 22 - 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Layout.headerHeight)
    }
}

/// 目录顶部的返回条：点击或按 Esc / ⌫ 回到上一级
private struct BackBar: View {
    @Environment(\.launcherLanguage) private var language
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
        .help(language.text("Go back", "返回上一级"))
        .padding(.leading, 4)
        .padding(.top, 8)
        .padding(.bottom, Layout.headerHeight - 22 - 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Layout.headerHeight)
    }
}

/// 摆放格子，并在定制模式下支持拖动排序。不用系统拖放（onDrag），而是格子自己跟着鼠标走：
/// 系统的拖动图像是另一张截图，松手后还要停留几帧才消失，和落位的格子同时出现。
/// 拖过同组的格子时其他格子实时让位（只改内存），松手时从当前位置弹回空位，并一次性写回配置
private struct Reorderable: ViewModifier {
    @ObservedObject var model: LauncherModel
    let index: Int
    let geo: GridGeometry
    let space: String

    func body(content: Content) -> some View {
        let dragging = model.dragIndex == index
        let o = dragging ? model.dragOrigin : geo.origins[index]
        let placed = content
            .overlay {
                if model.folderDropTarget == index {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15)))
                        .overlay(alignment: .bottom) {
                            Text(model.language.text("Move inside", "移入目录")).font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 4).background(.regularMaterial, in: Capsule())
                        }
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(dragging ? 1.08 : 1)
            .shadow(color: .black.opacity(dragging ? 0.25 : 0), radius: 8, y: 3)
            .offset(x: o.x, y: o.y)
            .zIndex(dragging ? 1 : 0)
        if model.canReorder {
            placed.gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
                    .onChanged { model.drag(index, start: $0.startLocation, location: $0.location, geo: geo) }
                    .onEnded { model.endDrag(location: $0.location, inGrid: geo.contains($0.location)) }
            )
        } else {
            placed
        }
    }
}

/// 每个格子在网格内容里的左上角坐标，和 entries 的排法一致
struct GridGeometry {
    private(set) var origins: [CGPoint]
    /// 每一行：顶边 y 和它包含的格子下标
    private var rows: [(y: CGFloat, indices: [Int])] = []
    private(set) var height: CGFloat = 0

    init(entries: [GridEntry], count: Int) {
        origins = Array(repeating: .zero, count: count)
        var y: CGFloat = 0
        for e in entries {
            let r = e.indices
            if r.isEmpty { y += e.height; continue }
            for (c, i) in r.enumerated() where i < count {
                origins[i] = CGPoint(x: CGFloat(c) * Layout.cellWidth, y: y)
            }
            rows.append((y, r))
            y += Layout.cellHeight
        }
        height = y
    }

    /// 松手的位置还在网格范围内（稍微出界一点也算），否则当作取消
    func contains(_ p: CGPoint) -> Bool {
        p.x > -20 && p.x < Layout.width - Layout.padding * 2 + 20 && p.y > -20 && p.y < height + 20
    }

    /// 某个位置落在哪一格；在一行末尾的空白处算这一行最后一格，落在标题上返回 nil。
    /// inset 是格子四周不算数的比例：位置要进到格子中间这一圈才算，避免在两格交界处来回跳
    func index(at p: CGPoint, inset: CGFloat = 0) -> Int? {
        guard let row = rows.last(where: { $0.y <= p.y }), p.y < row.y + Layout.cellHeight else { return nil }
        let fy = (p.y - row.y) / Layout.cellHeight
        guard fy >= inset, fy <= 1 - inset else { return nil }
        let col = p.x / Layout.cellWidth
        let c = Int(col)
        if c < row.indices.count {
            let fx = col - CGFloat(c)
            guard c >= 0, fx >= inset, fx <= 1 - inset else { return nil }
            return row.indices[c]
        }
        return row.indices.last
    }
}

/// 分组索引：固定位置排出各个分组，没有内容的置灰，位置不随应用增减变化。
/// 顺序模式是 固定 / A–Z / #，定制模式是 固定 / 应用（目录和应用混排在「应用」里）
private struct LetterIndex: View {
    @Environment(\.launcherLanguage) private var language
    static func letters(for mode: BrowseMode) -> [String] {
        switch mode {
        case .custom: return ["固定", "应用"]
        case .sorted: return ["固定"] + (65...90).map { String(UnicodeScalar($0)!) } + ["#"]
        }
    }

    let letters: [String]
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
                ForEach(letters, id: \.self) { letter in
                    let enabled = available.contains(letter)
                    let isHovered = enabled && hovered == letter
                    Text(language.section(letter))
                        .font(.system(size: letter.count > 1 ? 15 : 22, weight: .semibold))
                        .minimumScaleFactor(0.7).lineLimit(1)
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

/// Observe selection inside the tile, below its layout and drag modifiers.
/// The equality boundary keeps unchanged icons and labels out of the update.
private struct SelectedGridCell: View {
    let tile: Tile
    let index: Int
    @ObservedObject var selection: LauncherSelection

    var body: some View {
        GridCell(tile: tile, selected: selection.outlines(index)).equatable()
    }
}

private struct SelectedRow: View {
    let app: AppItem
    let index: Int
    @ObservedObject var selection: LauncherSelection

    var body: some View {
        Row(app: app, selected: selection.outlines(index))
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
            // 最多两行，键盘焦点边框跟随内容高度；同一行图标保持齐平。
            Text(name)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.tail)
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 4)
        }
        .padding(.vertical, 6)
        .frame(width: Layout.cellWidth - 4)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        // 指针只覆盖图标和名称，外层留白仍属于目录背景。
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .padding(.top, 2)
        .frame(width: Layout.cellWidth, height: Layout.cellHeight, alignment: .top)
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
        .foregroundStyle(Color.primary)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
        .pointerStyle(.link)
    }
}
