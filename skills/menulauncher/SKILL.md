---
name: menulauncher
description: Install, update, and organize MenuLauncher, a macOS menu bar app launcher. Use when the user wants to install or update MenuLauncher, pin apps to the top, hide apps, or group apps into (nested) folders in their launcher, or says things like "整理启动器 / 把这些应用放进一个目录 / 隐藏某个应用".
---

# MenuLauncher

MenuLauncher is a menu bar dropdown launcher for macOS 15+ (⌥Space or click the menu bar icon). The app does not sort by usage. Apps stay in fixed positions so the user can rely on spatial memory: a 固定 (pinned) section, then a 目录 (folders) section, then A–Z by name or pinyin. All organization lives in a JSON config file that you edit. The app reloads it automatically.

## Install and update

Install with Homebrew:

```sh
brew install --cask ykai55/tap/menulauncher
open -a MenuLauncher
```

Update with `brew upgrade --cask menulauncher`. This quits the running app, so reopen it with `open -a MenuLauncher` afterwards.

Without Homebrew, download `MenuLauncher.dmg` from https://github.com/ykai55/menubar-launcher/releases/latest and drag the app into /Applications. The app is not notarized, so run `xattr -dr com.apple.quarantine /Applications/MenuLauncher.app` before the first launch. The Homebrew cask does this for you.

The cask also installs a `menulauncher` command. If it is missing (for example after a DMG install), use `/Applications/MenuLauncher.app/Contents/MacOS/MenuLauncher` instead.

## Workflow for organizing

1. Run `menulauncher --list-apps` to get every installed app as JSON (`name`, `bundleId`, `path`, plus `pinned`, `hidden`, and `folder` when they apply). Names are localized, for example `终端` for Terminal. Match the user's wording against `name`, then write `bundleId` into the config.
2. Read the config at `~/.config/menulauncher/config.json` (`menulauncher --config-path` prints the path). If the file does not exist, start from `{}`.
3. Edit only what the user asked for and keep everything else, including existing order. Order in the file is the display order, and the user relies on positions staying put.
4. Run `menulauncher --check`. Exit 0 means OK. Exit 1 means the JSON is invalid; the app keeps its previous config and shows a warning banner, so fix it right away. Exit 2 means some references match no installed app; tell the user which ones.
5. You don't need to restart anything. The app reloads when the file changes.

## Config format

```json
{
  "pinned": ["com.apple.Safari", "com.tinyspeck.slackmacgap"],
  "hidden": ["com.apple.Chess", "/Applications/Old Tool.app"],
  "folders": [
    {
      "name": "开发",
      "apps": ["com.apple.Terminal", "com.microsoft.VSCode"],
      "folders": [
        { "name": "数据库", "apps": ["com.tinyapp.TablePlus"] }
      ]
    }
  ]
}
```

- Every key is optional.
- An app reference can be a bundle id (preferred, because it survives the app moving), an absolute path starting with `/` or `~`, or the exact displayed name. Matching is case-insensitive.
- `pinned`: shown in order at the top. Pinning is a shortcut, so a pinned app still appears in its folder or letter group.
- `hidden`: removed from the grid and from search.
- `folders`: shown as folder tiles in the 目录 section. They can nest to any depth through `folders`. An app that is in any folder no longer appears in the A–Z groups, but search still finds it. One app should be in at most one folder.
- Folder names must be non-empty and unique among siblings.

## Tips

- If the user asks to tidy up, propose a grouping (for example 开发 / 设计 / 办公 / 系统工具) and confirm it before writing, unless they told you to just do it.
- Never reorder existing entries on your own initiative.
- The user can also pin, hide, and remove apps from a folder through the right-click menu. Those changes are written back to the same file, so always re-read it before editing.
