---
name: menulauncher
description: Install, update, and organize MenuLauncher, a macOS menu bar app launcher. Use when the user wants to install or update MenuLauncher, pin apps to the top, hide apps, group apps into (nested) folders, or arrange the launcher based on how they actually use it, or says things like "整理启动器 / 把这些应用放进一个目录 / 隐藏某个应用 / 按我的使用习惯排一下".
---

# MenuLauncher

MenuLauncher is a menu bar dropdown launcher for macOS 15+ (⌥Space by default, configurable, or click the menu bar icon). Apps stay in fixed positions without usage-based sorting. 定制 (custom) mode shows pinned apps and a mixed grid of folders and unfiled apps, separated by a line, without titles or an index. Tiles can be dragged within their section. 顺序 (sorted) mode shows visible apps A–Z by name or pinyin and supports a section index. Choose the mode in Settings → General, or press Tab while browsing. The eye-slash button beside search opens the hidden area. All organization lives in a JSON config file that the app reloads automatically.

## Install and update

Install with Homebrew:

```sh
brew install --cask ykai55/tap/menulauncher
open -a MenuLauncher
```

Update with `brew upgrade --cask menulauncher`. This quits the running app, so reopen it with `open -a MenuLauncher` afterwards.

The app checks for stable releases on startup and panel opening, at most every six hours (15 minutes after a failed check). A newer version adds **Upgrade / 升级** in the top-right corner; clicking downloads, verifies, installs, and restarts while preserving config. **Check for updates… / 检查更新…** in the menu bar icon's right-click menu forces a check. In-app installation requires a writable app location and does not update Homebrew's installed-version records. If installation is blocked by permissions or a read-only disk image, use Homebrew or move the app into Applications.

Without Homebrew, download `MenuLauncher.dmg` from https://github.com/ykai55/menubar-launcher/releases/latest and drag the app into /Applications. The app is not notarized, so run `xattr -dr com.apple.quarantine /Applications/MenuLauncher.app` before the first launch. The Homebrew cask does this for you.

The cask also installs a `menulauncher` command. If it is missing (for example after a DMG install), use `/Applications/MenuLauncher.app/Contents/MacOS/MenuLauncher` instead.

### Last step of a fresh install: ask about a shortcut

After the app is running, ask the user how they want to open the panel. Use the host's multiple-choice question tool if there is one; otherwise list the options in the reply. Offer these, with ⌥Space first as the default:

- **⌥Space (Option-Space)**: the default, opens the panel under the menu bar icon. Nothing to write.
- **Another key combination**: ask which one, then write it to `hotkey`, for example `"hotkey": ["command+shift+l"]`. Mention that ⌥Space stops working unless they keep it in the list.
- **Mouse side button (back)**: opens with the first pinned icon centered under the cursor and the grid at the top; without pins, uses the first available icon. Shifts inward near screen edges. Writes `"mouse": [{"button": "back"}]`. The browser's Back on that button stops working.
- **Option + side button**: same, but the side button keeps working as Back in the browser. Writes `"mouse": [{"button": "back", "modifiers": ["option"]}]`.
- **Not now**: change nothing.

The user can pick a mouse option in addition to a keyboard shortcut. If they pick a mouse option:

1. Add the `mouse` entry to `~/.config/menulauncher/config.json` (create the file if needed and keep existing fields), then run `menulauncher --check`.
2. Tell them macOS will ask for the Accessibility permission (System Settings → Privacy & Security → Accessibility) and that the button starts working a few seconds after they turn MenuLauncher on, without a restart.
3. If the back button does nothing, have them try `forward`. Field details are under `mouse` in [Config format](#config-format).

Run `menulauncher --check` after writing `hotkey` too. Skip this question for updates and when the config already has a `mouse` or `hotkey` entry.

## Diagnose opening failures

Read `~/Library/Logs/MenuLauncher/launcher.log` around the reported time (and `launcher.log.1` after rotation). Follow `mouse.matched` → `mouse.delivered` → `panel.show_requested` → `panel.show_settled`; check `mouse.tap_create_failed`, `mouse.tap_disabled`, `main_loop.delay`, and `panel.hide_requested`'s `reason`. For menu bar right-clicks, check `status.clicked` and `status.menu_open/menu_closed`. Plain menu bar right-click opens a context menu; global right-click needs a configured modifier. The listener recovers every three seconds and after wake/session activation. These local diagnostics are independent of usage recording and contain no search or launched-app content.

Scans run in the background at startup, on manual Rescan, and after filesystem changes in application directories (one-second debounce). Changes during a scan request one follow-up; closing the popup does not scan. The existing app list remains available. Check `scan.watch_started` / `scan.watch_failed` and `scan.directory_changed` for notification delivery, then compare `scan.begin` / `scan.finished` (`duration_ms` and main-thread `apply_ms`) with the input log above.

## Workflow for organizing

1. Run `menulauncher --list-apps` to get every installed app as JSON (`name`, `bundleId`, `path`, plus `pinned`, `hidden`, and `folder` when they apply). Names are localized, for example `终端` for Terminal. Match the user's wording against `name`, then write `bundleId` into the config.
2. Read the config at `~/.config/menulauncher/config.json` (`menulauncher --config-path` prints the path). If the file does not exist, start from `{}`.
3. Edit only what the user asked for and keep everything else, including existing order. Order in the file is the display order, and the user relies on positions staying put.
4. Run `menulauncher --check`. Exit 0 means OK. Exit 1 means the JSON is invalid; the app keeps its previous config and shows a warning banner, so fix it right away. Exit 2 means some references match no installed app; tell the user which ones.
5. You don't need to restart anything. The app reloads when the file changes.

## Arranging by usage

The app records usage locally in `~/.config/menulauncher/usage.jsonl` and never uploads it. It logs one JSON line per panel open (`trigger`: `hotkey` or `click`) and per app launch (`via`: `pinned`, `grid`, `folder`, or `search`, plus the search `query` or the `folder` path). The app never reorders anything by itself. When the user asks you to arrange things by how they use them, you make the change:

1. Run `menulauncher --stats` (or `--stats 30` for the last 30 days). You get JSON with `apps` sorted by `launches`, each with `lastUsed`, a `via` breakdown, and the search `queries` used to reach it.
2. Propose changes, then confirm them with the user before writing:
   - Pin apps that are launched often, especially ones the user keeps finding via `search` or digging out of the grid. Keep the pinned list short, around 6–12.
   - Apps that are always opened through search are fine as they are. Searching is already fast, so pin them only if the user agrees.
   - Suggest hiding installed apps that never appear in the stats, or moving them into a folder. Stats only cover the time since recording started (`since`), so be careful with a short history.
   - Put pinned apps in a stable order, for example by frequency. After that, don't keep reshuffling them on every run, because the user memorizes positions.
3. Edit the config and run `--check` as usual.

If the user doesn't want recording, set `"recordUsage": false` in the config. To clear the history, delete `usage.jsonl`.

## Config format

Settings are available through the gear beside search, the menu bar icon's **Settings…** menu, or ⌘, while the panel is open. General includes language, browse mode (Custom / A–Z), and local usage recording; Shortcuts includes keyboard and mouse bindings. Save applies only preferences changed in that window. Browse mode is stored in macOS preferences; other settings are merged into the same JSON file. `menulauncher --settings` opens settings on launch. Preserve these preferences when organizing apps.

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
- `language`: `"system"` (default), `"en"`, or `"zh-Hans"`. Controls launcher UI and CLI messages; app names follow macOS and user folder names are unchanged. English documentation is in README.md and Chinese documentation in README.zh-CN.md.
- An app reference can be a bundle id (preferred, because it survives the app moving), an absolute path starting with `/` or `~`, or the exact displayed name. Matching is case-insensitive.
- `pinned`: shown in order at the top. Pinning is a shortcut, so a pinned app still appears in its folder or letter group.
- Top-level `hidden`: app references excluded from ordinary browsing and search. They remain accessible in the hidden area, which also has its own app search. Remove a reference to restore the app.
- `folders`: shown as folder tiles in 定制 mode. They can nest through `folders`. Filed apps are excluded from the unfiled grid; ordinary sorted mode and search still show them unless hidden. One app should be in at most one folder.
- Folder-level `hidden`: boolean, default `false`. Set `"hidden": true` on the exact folder object to hide it, its descendants, and their apps from normal browsing, pinned shortcuts, and search. The hidden area keeps the subtree navigable. Set it to `false` or remove it to restore the folder; descendants with their own `hidden: true` and apps in top-level `hidden` remain hidden. Keep `apps`, `folders`, `pinned`, and `order` unchanged when hiding/restoring. `--list-apps` reports `hidden: true` for apps hidden through a folder too.
- Folder names must be non-empty and unique among siblings.
- `order`: the mixed order of folders and unfiled apps in the 应用 section in 定制 mode. Apps are written as references, folders as `"folder:<name>"`. Unlisted folders come first in `folders` order, unlisted apps come last by name. A folder can have its own `order` with the same format for its subfolders and apps (unlisted subfolders first, then apps in `apps` order). Dragging writes `pinned`, top-level `order`, and folder `order`. If you rename a folder, update its `folder:` entries too.
- `recordUsage`: set to `false` to stop writing `usage.jsonl`. Defaults to `true`.
- `hotkey`: global shortcuts that open the panel under the menu bar icon. Defaults to `["option+space"]` when absent; `[]` turns keyboard shortcuts off. A single string is accepted.
  - Format: modifiers (`command`, `option`, `control`, `shift`) and one key joined by `+`, for example `"command+shift+l"`. Keys: `a`–`z`, `0`–`9`, `space`, `return`, `tab`, `escape`, `delete`, arrows (`left` / `right` / `up` / `down`), `home`, `end`, `pageup`, `pagedown`, `f1`–`f20`, and `` ` - = [ ] \ ; ' , . / ``. Letters follow the US key positions.
  - A key without modifiers is only allowed for F keys. `--check` warns about unknown or unsafe shortcuts, and the app ignores them.
  - If another app already owns the combination, Settings shows the registration failure; suggest a different one. Settings rejects invalid, unsafe, or duplicate shortcuts before saving.
- `mouse`: mouse buttons that open the panel at the cursor, for example `[{"button": "back"}, {"button": "forward", "modifiers": ["option"]}]`.
  - `button` is `back`, `forward`, `middle`, or a button number (3 = back, 4 = forward, 5+ for extra buttons).
  - `modifiers` takes `command`, `option`, `control`, or `shift`, and must match exactly.
  - A matching click is swallowed, so a bare `back` no longer means Back in the browser. Suggest a modifier combination if the user still wants the browser to get it.
  - Left and right buttons (0/1) require a modifier. This needs the Accessibility permission (System Settings → Privacy & Security → Accessibility). The app prompts for it once and starts working as soon as it is granted.
  - If the user doesn't know their button number, have them try `back` and `forward` first.

## Tips

- If the user asks to tidy up, propose a grouping (for example 开发 / 设计 / 办公 / 系统工具) and confirm it before writing, unless they told you to just do it.
- Never reorder existing entries on your own initiative.
- The user can pin/hide apps, hide whole folders, and restore items through right-click menus. Hidden folders appear at the hidden area's root unless an ancestor is already hidden; Back/Esc/blank-area clicks return one level. Closing the panel exits the hidden area. These changes are written to the same config, so re-read it before editing.
- In custom mode, folder centers accept a drop after about 0.4 seconds and show **移入目录**. Edges show an insertion line for sorting: hold about 0.18 seconds for a preview or release to insert immediately. Brief edge crossings do not push folders away. Apps moved inside leave their previous folder but keep pinned shortcuts; folders keep their subtrees. The destination appends the item after existing contents. Self/descendant moves and duplicate child folder names are rejected. Re-read config after a drag because it updates membership and `order` together.
