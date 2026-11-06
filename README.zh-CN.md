# MenuLauncher

[English](README.md) | 简体中文

macOS 菜单栏应用启动器。按 ⌥Space 或点击菜单栏图标，就能打开位置固定的应用网格。支持两种模式，可通过搜索框旁的开关或 Tab 切换：

- **定制**：固定应用在顶部，分割线下是目录和未归入目录的应用。同一分组内可以拖动排序，没有分组标题和字母索引。
- **顺序**：先显示固定应用，再按名称首字母排列所有可见应用；中文按拼音排序，不受目录层级影响。点击分组标题可跳到指定字母。

支持名称、拼音（`weixin`）和首字母（`wx`、`vsc`）搜索，也支持固定、隐藏应用及嵌套目录。搜索框旁的划线眼睛按钮可进入隐藏区，浏览、启动和恢复隐藏项。应用不会根据使用频率自动排序，位置由你决定。界面支持简体中文和英文。

需要 macOS 15 或更高版本，安装包同时支持 Apple 芯片和 Intel。

## 安装

```sh
brew install --cask ykai55/tap/menulauncher
open -a MenuLauncher
```

更新时运行 `brew upgrade --cask menulauncher`，完成后重新打开应用。

也可以从 [Releases](https://github.com/ykai55/menubar-launcher/releases/latest) 下载 `MenuLauncher.dmg`，将应用拖入“应用程序”。应用尚未公证，首次启动前运行：

```sh
xattr -dr com.apple.quarantine /Applications/MenuLauncher.app
```

## 设置

点击搜索框旁的齿轮，或右键菜单栏图标选择**设置…**。面板打开时也可以按 **⌘,**。启动应用时可用 `menulauncher --settings` 直接进入设置。

- **通用**：选择跟随系统、简体中文或英文；开关本机使用记录；打开配置文件；重新扫描应用。
- **快捷键**：每行填写一个键盘快捷键，添加或移除鼠标触发，打开系统辅助功能设置。

点击**保存**或按 **⌘S** 后立即生效；**取消**放弃未保存的修改。无效的快捷键和鼠标触发会被拒绝；快捷键注册失败时，窗口会提示哪些组合可能已被占用。

设置和应用布局共用 `~/.config/menulauncher/config.json`。保存前会重新读取文件，只更新你改动的设置，不覆盖期间由拖动或外部编辑产生的目录、固定、隐藏和排序调整。

配置中的 `language` 可填 `"system"`（默认）、`"en"` 或 `"zh-Hans"`。跟随系统时，从系统首选语言中选择中文或英文；没有匹配项则使用英文。切换语言会更新启动器界面和命令行提示。应用名称仍跟随 macOS，自定义目录名保持原样。旧配置无需修改。

## 整理应用

右键应用可以固定到顶部、隐藏或移出目录，也可以直接编辑配置文件，保存后自动生效：

```json
{
  "pinned": ["com.apple.Safari"],
  "hidden": ["com.apple.Chess"],
  "folders": [
    {
      "name": "开发",
      "apps": ["com.apple.Terminal"],
      "folders": [{ "name": "数据库", "apps": [] }]
    }
  ]
}
```

应用引用支持 bundle id、路径或显示名称。Homebrew 安装会提供 `menulauncher` 命令：

```sh
menulauncher --list-apps   # 以 JSON 列出应用、bundle id 和当前状态
menulauncher --check       # 校验配置
menulauncher --config-path # 打印配置文件路径
menulauncher --stats 30    # 最近 30 天的使用汇总（JSON）
```

### 隐藏区

右键目录选择**隐藏目录**，或在该目录配置中加入 `"hidden": true`，即可隐藏整个子树及其中的应用。普通浏览、搜索和固定区都不再显示它们。

隐藏区会列出隐藏目录和单独隐藏的应用，其中的搜索只查找隐藏应用。右键选择**取消隐藏目录**或**取消隐藏**即可恢复。恢复目录时，单独设置过隐藏的应用和子目录仍保留各自的隐藏状态；原有目录归属和顺序不变。

点击返回条、按 Esc 或退格键、点击空白区域都能返回上一级。关闭启动面板会退出隐藏区。

### 拖动整理

定制模式下，拖动到目录中央停留约 0.4 秒，出现**移入目录**高亮后松手即可移入。拖到目录边缘时显示插入线，停留约 0.18 秒可预览排序，也可以直接松手插入。短暂经过边缘不会把目录挤开，移走鼠标会取消待执行操作。

移入的项目追加到现有内容之后。应用保留固定快捷方式，目录保留整个子树。目录不能移入自身、后代目录，或已经有同名子目录的目标。

### 键盘快捷键

默认使用 ⌥Space。可以在设置中修改，也可以编辑 `hotkey`：

```json
{ "hotkey": ["command+shift+l", "f13"] }
```

修饰键 `command`、`option`、`control`、`shift` 与按键用 `+` 连接。支持字母、数字、`space`、`return`、`tab`、`escape`、方向键、`f1`–`f20` 及 `,`、`/` 等标点。也接受单个字符串。`[]` 表示关闭键盘快捷键；只有 F1–F20 可以不带修饰键。保存后立即生效。

### 鼠标触发

使用鼠标侧键或“修饰键 + 鼠标键”，在光标位置打开面板：

```json
{ "mouse": [{ "button": "back" }, { "button": "forward", "modifiers": ["option"] }] }
```

支持 `back`、`forward`、`middle` 或非负按键编号，左右键必须搭配修饰键。此功能需要系统辅助功能权限。匹配的点击会被拦截，不再同时触发浏览器前进或后退。

### 使用记录

面板打开和应用启动事件保存在本机 `~/.config/menulauncher/usage.jsonl`，包含启动来源（固定、网格、目录或搜索词），不会上传。记录供你或 agent 整理应用时参考，启动器不会据此改变顺序。

在设置中关闭“在本机记录使用情况”，或配置 `"recordUsage": false`，即可停止记录。已有记录保留。

### 让 agent 整理

安装附带的 skill：

```sh
npx skills add ykai55/menubar-launcher
```

然后可以直接说“把开发相关的应用放进一个开发目录，隐藏国际象棋”，或“按最近一个月的使用情况整理固定区”。配置格式和操作方法见 [skill 文档](skills/menulauncher/SKILL.md)。

## 构建

```sh
./build-app.sh            # build/MenuLauncher.app，本机架构
./make-dmg.sh             # build/MenuLauncher.dmg，通用架构
./make-release.sh X.Y.Z   # 可选：设置版本下限并推送 main
```

## 持续部署

每次推送 `main`，GitHub Actions 都会运行测试，构建通用 DMG、ZIP 和 `menulauncher-skill.zip`，发布 GitHub Release，并更新 Homebrew cask。发布串行执行；排队期间已被更新提交替代的版本会跳过。也可以在 Actions 页面针对 main 手动触发。

发布版本取 `VERSION` 与已有最高版本 tag 的下一补丁版本中的较大值。流水线为实际源码提交创建 tag，不回写 main。若要升级主版本或次版本，可以修改 `VERSION` 后推送，或执行 `./make-release.sh X.Y.Z`。

失败后重跑会复用原 tag。已经公开的安装包保持不变；流水线会下载已发布 ZIP，重试 Homebrew 更新。仓库 secret `TAP_DEPLOY_KEY` 需要有 `ykai55/homebrew-tap` 的写权限。
