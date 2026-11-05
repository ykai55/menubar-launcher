# MenuLauncher

macOS 菜单栏下拉式应用启动器（Swift Package，SwiftUI + AppKit，无第三方依赖）。这个目录放启动器的源码、打包和发版脚本、给 agent 用的 skill。GitHub 仓库是 ykai55/menubar-launcher，Homebrew tap 是 ykai55/homebrew-tap（`Casks/menulauncher.rb`）。

- 构建打包：`./build-app.sh` → `build/MenuLauncher.app`（本机 Swift 6.4 需要 `--build-system native`，否则报 developer directory 错误）。版本号读 `VERSION` 文件
- 分发：`./make-dmg.sh` → `build/MenuLauncher.dmg`（arm64 + x86_64 通用二进制，ad-hoc 签名、未公证，别人首次打开前要 `xattr -dr com.apple.quarantine`；cask 的 postflight 会自动做）
- 发版：`./make-release.sh X.Y.Z`：写 VERSION、打 DMG/zip、打 tag 推送、`gh release create`、更新 tap 里 cask 的 version/sha256（cask 下载的是 zip）
- 源码在 `Sources/MenuLauncher/`：`AppIndex`（扫描应用、bundle id、拼音关键词）、`Config`（config.json 读写、应用引用匹配）、`CLI`（`--list-apps` / `--check` / `--config-path`，不启动界面）、`LauncherModel`（浏览网格：固定 / 目录 / A–Z，目录导航，隐藏，搜索打分，配置文件监听）、`LauncherView`（图标网格、目录格子、搜索结果列表）、`AppDelegate`（状态栏图标、下拉面板、键盘处理）、`HotKey`（Carbon 全局快捷键，默认 ⌥Space）
- 配置：`~/.config/menulauncher/config.json`（`MENULAUNCHER_CONFIG` 环境变量可覆盖，测试用），字段 pinned / hidden / folders（可嵌套）。同时监听目录（原子替换写入）和文件本身（原地写入）。JSON 出错时保留上次配置并在面板顶部显示错误。旧版 UserDefaults 里的 pinned 首次启动时迁移进配置
- `skills/menulauncher/SKILL.md`：教 agent 安装/更新、用 CLI 列应用、改配置、校验。改配置格式或 CLI 时同步更新它和 README
- 最低系统版本 macOS 15（用到 `onScrollGeometryChange`）；Info.plist 必须声明 `CFBundleLocalizations` 含中文，否则应用名会显示成英文
- Safari 在 `/System/Cryptexes/App/System/Applications`，/Applications 下的是带 hidden 标志的符号链接，扫描时要单独加这个目录
- 设计原则：利用空间记忆，应用位置稳定。不做使用频率等智能排序；配置里的顺序就是显示顺序
- 经验：不要绑定 `scrollPosition`（hover 刷新时会把列表拉回旧位置）；滚动中频繁变化的值不要 @Published；不要在 @Published 的 didSet 里再赋值
