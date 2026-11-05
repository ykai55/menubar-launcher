# MenuLauncher

macOS 菜单栏下拉式应用启动器（Swift Package，SwiftUI + AppKit，无第三方依赖）。这个目录放启动器的源码、打包和发版脚本、给 agent 用的 skill。GitHub 仓库是 ykai55/menubar-launcher，Homebrew tap 是 ykai55/homebrew-tap（`Casks/menulauncher.rb`）。

- 构建打包：`./build-app.sh` → `build/MenuLauncher.app`（本机 Swift 6.4 需要 `--build-system native`，否则报 developer directory 错误）。版本号读 `VERSION` 文件
- 分发：`./make-dmg.sh` → `build/MenuLauncher.dmg`（arm64 + x86_64 通用二进制，ad-hoc 签名、未公证，别人首次打开前要 `xattr -dr com.apple.quarantine`；cask 的 postflight 会自动做）
- 发版：`./make-release.sh X.Y.Z`：要求工作区干净，写 VERSION、提交、打 tag 推送。推送 `v*` tag 触发 `.github/workflows/release.yml`（macos-26 runner）：校验 VERSION 与 tag 一致、`make-dmg.sh` 打通用二进制、`gh release create` 上传 DMG/zip、用 secret `TAP_DEPLOY_KEY`（homebrew-tap 仓库的可写 deploy key）更新 cask 的 version/sha256（cask 下载的是 zip）。失败了修好后删 tag 和 Release 重推，或在 Actions 里 re-run
- 源码在 `Sources/MenuLauncher/`：`AppIndex`（扫描应用、bundle id、拼音关键词）、`Config`（config.json 读写、应用引用匹配）、`CLI`（`--list-apps` / `--check` / `--config-path` / `--stats`，不启动界面）、`LauncherModel`（浏览网格分两种模式：定制模式 固定 / 应用（目录和应用混排，可拖动排序，同分组内；格子不分行放，全部在同一个 ZStack 里按 GridGeometry 坐标摆，跨行让位才是同一个视图移动（分行 HStack 会出现两个相同图标）；不用系统拖放（onDrag 的拖动图像松手后会多停几帧，和落位格子叠成两个），用 DragGesture 让格子本身跟着鼠标走；按图标中心、进入格子中间一圈才换位，避免在行交界处来回跳；拖动中只改内存，松手时图标从落点移入并写回 pinned / order / 目录 order；拖到面板外松手靠轮询鼠标键判定取消；拖到可视区上下边缘 40pt 内由 60Hz 定时器自动滚动（定时器要加到 .common 模式，滚动靠 scrollTo 一个用 alignmentGuide 放在目标偏移处的锚点，每帧按滚动量修正鼠标的网格坐标重新判断换位）；松手后写配置会经 refilter 把选中项重置成首个可见格，所以 endDrag 最后按 tileKey 把选中项放回落定的格子），顺序模式 固定 / A–Z 全部应用；Tab 或搜索框旁的开关切换，模式和各自的滚动位置存 UserDefaults，面板高度取两种模式顶层的较大值；目录导航，隐藏，搜索打分，配置文件监听）、`LauncherView`（图标网格、目录格子、搜索结果列表）、`AppDelegate`（状态栏图标、下拉面板、键盘处理）、`HotKey`（Carbon 全局快捷键；`Shortcut` 解析配置 `hotkey` 里的 "option+space" 写法，不写时默认 ⌥Space，`[]` 关闭，无修饰键只允许 F 键；配置变化时先释放旧的再重新注册，多个快捷键靠 EventHotKeyID 区分）
- 配置：`~/.config/menulauncher/config.json`（`MENULAUNCHER_CONFIG` 环境变量可覆盖，测试用），字段 hotkey / mouse / pinned / hidden / folders（可嵌套）/ order（定制模式顶层目录和应用混排顺序，目录写 "folder:名字"；目录内也可有 order）。同时监听目录（原子替换写入）和文件本身（原地写入）。JSON 出错时保留上次配置并在面板顶部显示错误。旧版 UserDefaults 里的 pinned 首次启动时迁移进配置
- 鼠标触发：`MouseTrigger.swift` 用 CGEventTap 监听配置 `mouse` 里的鼠标键（+修饰键），匹配到就吞掉按下和松开事件，并在鼠标处打开面板（`positionAtMouse`）。需要辅助功能权限，没有时提示一次并每 3 秒重试。ad-hoc 签名默认按 cdhash 匹配，每次编译都变，授权会失效（设置里显示已开但不生效、每次启动都弹）。所以 build-app.sh / make-dmg.sh 签名时指定 `-r='designated => identifier "local.menulauncher"'`，按 bundle id 匹配。授权状态乱了可以 `tccutil reset Accessibility local.menulauncher` 后重新授权
- 使用记录：`Usage.swift` 往配置同目录的 `usage.jsonl` 追加 open（hotkey/click）和 launch（via pinned/grid/folder/search，带 query 或 folder）事件，后台队列写入；`--stats [天数]` 汇总。配置 `recordUsage: false` 关闭。应用自己不按它排序，只给 agent 参考
- `skills/menulauncher/SKILL.md`：教 agent 安装/更新、用 CLI 列应用、改配置、校验。改配置格式或 CLI 时同步更新它和 README
- 最低系统版本 macOS 15（用到 `onScrollGeometryChange`）；Info.plist 必须声明 `CFBundleLocalizations` 含中文，否则应用名会显示成英文
- Safari 在 `/System/Cryptexes/App/System/Applications`，/Applications 下的是带 hidden 标志的符号链接，扫描时要单独加这个目录
- 设计原则：利用空间记忆，应用位置稳定。不做使用频率等智能排序；配置里的顺序就是显示顺序
- 经验：不要绑定 `scrollPosition`（hover 刷新时会把列表拉回旧位置）；滚动中频繁变化的值不要 @Published；不要在 @Published 的 didSet 里再赋值
