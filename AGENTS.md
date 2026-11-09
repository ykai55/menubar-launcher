# MenuLauncher

macOS 菜单栏下拉式应用启动器（Swift Package，SwiftUI + AppKit，无第三方依赖）。这个目录放启动器的源码、打包和发版脚本、给 agent 用的 skill。GitHub 仓库是 ykai55/menubar-launcher，Homebrew tap 是 ykai55/homebrew-tap（`Casks/menulauncher.rb`）。

- 构建打包：`./build-app.sh` → `build/MenuLauncher.app`（本机 Swift 6.4 需要 `--build-system native`，否则报 developer directory 错误）。版本号读 `VERSION` 文件
- 分发：`./make-dmg.sh` → `build/MenuLauncher.dmg`（arm64 + x86_64 通用二进制，ad-hoc 签名、未公证，别人首次打开前要 `xattr -dr com.apple.quarantine`；cask 的 postflight 会自动做）
- 发版：推送 main 自动测试、发布通用 DMG/ZIP 和 skill ZIP、更新 Homebrew；规则见 README 的 Continuous deployment。VERSION 是版本下限，CI 自动递增补丁号并打 tag，不回写 main。`./make-release.sh X.Y.Z` 可选设置下限并推送 main。失败后直接重跑 Actions，复用 tag 和已公开的安装包；`TAP_DEPLOY_KEY` 须能写 homebrew-tap。
- 源码在 `Sources/MenuLauncher/`：`AppIndex`（扫描应用、bundle id、拼音关键词）、`Config`（config.json 读写、应用引用匹配）、`CLI`（`--list-apps` / `--check` / `--config-path` / `--stats`，不启动界面）、`LauncherModel`（定制模式 固定 / 应用，目录和应用混排；顺序模式 固定 / A–Z 全部应用；设置 → 通用或 Tab 切换，模式和各自的滚动位置存 UserDefaults，面板高度取两种模式顶层的较大值；目录导航、隐藏、搜索打分、配置文件监听）、`LauncherView`（图标网格、目录格子、搜索结果列表）、`AppDelegate`（状态栏图标、下拉面板、键盘处理）、`HotKey`（Carbon 全局快捷键；`Shortcut` 解析配置 `hotkey`，缺省 ⌥Space，`[]` 关闭，无修饰键只允许 F 键；配置变化时先释放旧注册，多个快捷键靠 EventHotKeyID 区分）
- 拖动排序：仅定制模式、同分组内。格子在同一个 ZStack 中按 GridGeometry 坐标摆放，跨行保持视图身份。DragGesture 移动格子本身，避免原生 onDrag 的残留图像；图标中心进入目标格内圈才换位，避免行边界反复跳动。拖动只改内存，松手写 pinned / order / 目录 order，取消则恢复快照。隐藏、搜索、换层和外部配置更新时取消拖动并停止定时器。
- 拖动滚动：内容中的 `DragScrollSurface` 取得所属 NSScrollView，60Hz `.common` 定时器在上下边缘 40pt 内调用 NSClipView.scroll(to:)。按实际 bounds 偏移修正鼠标的网格坐标，兼容鼠标静止和滚轮滚动。旧的 alignmentGuide 移动锚点 + scrollTo 只改变模型偏移，实际内容不滚动，不能复用。
- 拖动选中：applyConfig 重建前保存 tileKey，refilter 不重置选中项，重建后按身份恢复。只在 endDrag 末尾恢复不够：中途发布 selection=0 会让首格短暂高亮。回归测试 `swift test --build-system native` 检查发布的选中序列、实际 NSScrollView 偏移、图标位置、滚动边界和取消行为。
- 鼠标与键盘反馈：图标、目录和搜索行用 `.pointerStyle(.link)` 显示手型，hover 不改 selection，也不填充背景。键盘操作时显示 1.5pt 强调色边框；实际鼠标移动、按下或滚轮事件隐藏边框，键盘驱动的滚动不隐藏。面板重新打开时默认无边框。`selection` 和 `showsKeyboardFocus` 属于独立的 `LauncherSelection`，只有 SelectedGridCell / SelectedRow 观察；不要放回 LauncherModel 的 @Published，以免带动网格、Reorderable 和窗口 resize。SelectionTests 锁住输入方式切换与发布边界；`MENULAUNCHER_PERF_CHECK=1 swift test -c release --build-system native --filter ScrollPerformanceTests` 测滚动与焦点更新耗时，普通 CI 跳过依赖机器速度的断言。
- 目录空白点击：ScrollView 内的内容至少铺满可视高度，contentShape 和返回手势挂在内容本身；放在 ScrollView 背后的 background 收不到下方空白点击。GridCell 的命中区域放在外层定高 frame 之前，让图标间隙属于背景。返回时核对 levelKey，避免子目录点击触发二次导航。点击回归测试通过 NSWindow.sendEvent 投递事件；窗口须先 orderFront（测试用 alpha=0），未加入窗口顺序时 SwiftUI 手势不会收到事件。
- 定制模式没有分组标题或索引；固定和主列表同时非空时插入 `.divider`。所有滚动恢复、GridGeometry 和高度计算统一用 GridEntry.height；顺序模式保留标题和索引。
- 拖进目录与排序：按光标分区，中央半宽/60% 高度停留 0.4 秒后显示「移入目录」；边缘设置 folderInsertion 并显示前/后插入线，0.18 秒预览让位，松手立即插入。进入中央、离开或取消时清除另一候选；松手重新计算位置。不要让旧的图标中心排序提前挤走可接收目录，也不要锁住整个目录不让排序。测试覆盖连续接近、文字抓取、边缘久停与快速松手。移入只写本次目录变更；Config.moveApp 清除旧成员/顺序引用但保留 pinned，moveFolder 保留子树并修正目标下标，拒绝自包含、后代和同名子目录。追加前展开隐式 order。
- 目录可设 `hidden: true`，隐藏整个子树及其中应用（含固定、顺序列表、普通搜索）。搜索框右侧按钮进入隐藏区：顶层列最外层隐藏目录和不在这些目录内的单独隐藏应用，目录内部显示完整子树，搜索只搜隐藏应用。hiddenRootPath 记录入口，返回不会穿入普通父目录。隐藏区禁止拖动，关闭面板退出；右键恢复时保持原配置引用，拖动普通列表时保留隐藏引用在 order 中的槽位。Config 的隐藏判定供 UI 和 CLI 共用，新增验证在 VisibilityTests。
- 配置：`~/.config/menulauncher/config.json`（`MENULAUNCHER_CONFIG` 环境变量可覆盖，测试用），字段 hotkey / mouse / pinned / hidden / folders（可嵌套）/ order（定制模式顶层目录和应用混排顺序，目录写 "folder:名字"；目录内也可有 order）。同时监听目录（原子替换写入）和文件本身（原地写入）。JSON 出错时保留上次配置并在面板顶部显示错误。旧版 UserDefaults 里的 pinned 首次启动时迁移进配置
- 鼠标触发：`MouseTrigger.swift` 用 CGEventTap 监听配置 `mouse` 里的鼠标键（+修饰键），匹配到就吞掉按下和松开事件，并在鼠标处打开面板（`positionAtMouse`）。需要辅助功能权限，没有时提示一次并每 3 秒重试。ad-hoc 签名默认按 cdhash 匹配，每次编译都变，授权会失效（设置里显示已开但不生效、每次启动都弹）。所以 build-app.sh / make-dmg.sh 签名时指定 `-r='designated => identifier "local.menulauncher"'`，按 bundle id 匹配。授权状态乱了可以 `tccutil reset Accessibility local.menulauncher` 后重新授权
- 使用记录：`Usage.swift` 往配置同目录的 `usage.jsonl` 追加 open（hotkey/click）和 launch（via pinned/grid/folder/search，带 query 或 folder）事件，后台队列写入；`--stats [天数]` 汇总。配置 `recordUsage: false` 关闭。应用自己不按它排序，只给 agent 参考
- `skills/menulauncher/SKILL.md`：教 agent 安装/更新、用 CLI 列应用、改配置、校验。改配置格式或 CLI 时同步更新它和 README
- 最低系统版本 macOS 15（用到 `onScrollGeometryChange`）；Info.plist 必须声明 `CFBundleLocalizations` 含中文，否则应用名会显示成英文
- Safari 在 `/System/Cryptexes/App/System/Applications`，/Applications 下的是带 hidden 标志的符号链接，扫描时要单独加这个目录
- 设计原则：利用空间记忆，应用位置稳定。不做使用频率等智能排序；配置里的顺序就是显示顺序
- 本地化：`Localization.swift` 的 AppLanguage 支持 system / en / zh-Hans，配置缺省跟随系统；界面和 CLI 都要提供中英文。README.md 全英文，README.zh-CN.md 全中文（语言切换链接除外）。只翻译展示标签，固定 / 应用等内部 key 不变，不翻译用户目录名。
- 设置：`SettingsView.swift` 是 AppDelegate 持有的独立原生窗口，齿轮、右键菜单或 ⌘, 打开。`PreferencesDraft` 保存时与窗口初始值比较，仅合并改动过的偏好到磁盘最新配置；先保存成功再 applyConfig，错误时不覆盖磁盘或应用内配置。新增配置或入口时同步两份 README 和 skill。
- 设置中的浏览模式也经过草稿和保存流程，保存配置成功后才调用 setMode，沿用 UserDefaults 持久化；未改模式时保留通过面板切换的结果。
- 每次打开设置先在 hide/activate 前取得可见弹窗的 screen，在该屏幕 visibleFrame 内居中；无可见弹窗时优先鼠标所在屏幕。复用已打开的设置窗口时保留草稿，也要重新定位。
- 原生控件点击测试：NSSwitch 等控件会在 mouseDown 内进入 tracking loop，不能顺序 sendEvent(down) 再 sendEvent(up)。先用 NSApp.postEvent 排队 mouseUp，再发送 mouseDown；SwiftUI 控件未消费的 mouseUp 由测试取出补发。SettingsWindowTests 覆盖两种语言下保存、取消、切页及鼠标触发添加。
- 经验：不要绑定 `scrollPosition`（hover 刷新时会把列表拉回旧位置）；滚动中频繁变化的值不要 @Published；不要在 @Published 的 didSet 里再赋值
