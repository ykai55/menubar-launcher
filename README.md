# MenuLauncher

A macOS menu bar dropdown app launcher. Press ⌥Space or click the menu bar icon to get an icon grid with a fixed layout. It has two modes, switched with the toggle next to the search box or Tab: **定制 (custom)** shows pinned apps, a divider, then your folders mixed with unfiled apps, without section titles or an index. You can drag folders and apps to reorder them within their section. **顺序 (sorted)** shows 固定 then visible apps A–Z by name (Chinese names sort by pinyin), ignoring folder hierarchy. There is no usage-based sorting, so apps stay where you remember them.

- Type to search by name, pinyin (`weixin`), initials (`wx`, `vsc`)
- In sorted mode, click a section header to jump to a letter
- Pin and hide apps, organize them into nested folders, or hide whole folders
- Open the hidden area with the eye-slash button beside search to browse, launch, and restore hidden items
- Your AI agent can organize everything for you: the layout is a plain JSON file, and an [agent skill](skills/menulauncher/SKILL.md) is included

Requires macOS 15+. Universal binary (Apple silicon + Intel).

## Install

```sh
brew install --cask ykai55/tap/menulauncher
open -a MenuLauncher
```

Update with `brew upgrade --cask menulauncher`.

Or download `MenuLauncher.dmg` from [Releases](https://github.com/ykai55/menubar-launcher/releases/latest). The app is not notarized, so before the first launch run:

```sh
xattr -dr com.apple.quarantine /Applications/MenuLauncher.app
```

## Organize

Use the right-click menu on an app (固定 / 隐藏 / 移出目录), or edit `~/.config/menulauncher/config.json`. The app reloads the file on save:

```json
{
  "pinned": ["com.apple.Safari"],
  "hidden": ["com.apple.Chess"],
  "folders": [
    { "name": "开发", "apps": ["com.apple.Terminal"], "folders": [{ "name": "数据库", "apps": [] }] }
  ]
}
```

Right-click a folder and choose **隐藏目录**, or add `"hidden": true` to that folder object. This hides the folder, its descendants, and their apps from ordinary browsing and search, including pinned shortcuts. The hidden area lists hidden folders and individually hidden apps; search there covers hidden apps. Use **取消隐藏目录** or **取消隐藏** in its right-click menus to restore items. Apps hidden through a folder become visible when that folder is restored; independently hidden apps keep their own hidden setting. Existing folder membership and ordering are preserved.

In the hidden area, the back bar, Esc, Backspace, or a blank-area click returns one level. Closing the panel exits the hidden area.

In custom mode, folder centers and edges have different drag actions. Hold over the center for about 0.4 seconds, then release after the **移入目录** highlight to move inside. Near an edge, an insertion line shows where the item will go; hold for about 0.18 seconds to preview reordering, or release immediately to insert. Briefly crossing an edge does not push the folder away. Moving away cancels the pending action. Items moved inside are appended after existing contents. Pinned shortcuts remain pinned, and folders keep their subtrees. A folder cannot move into itself, its descendants, or a destination with a child folder of the same name.

App references can be bundle ids, paths, or display names. Helper commands (the cask links `menulauncher` into your PATH):

```sh
menulauncher --list-apps   # installed apps as JSON, with bundle ids and current state
menulauncher --check       # validate the config
menulauncher --stats 30    # usage summary for the last 30 days (JSON)
```

### Shortcut

The panel opens with ⌥Space by default. Change it, add more, or turn it off with `hotkey`:

```json
{ "hotkey": ["command+shift+l", "f13"] }
```

Write modifiers (`command`, `option`, `control`, `shift`) and a key joined by `+`. Keys are letters, digits, `space`, `return`, `tab`, `escape`, arrows, `f1`–`f20`, and punctuation such as `,` or `/`. A single string works too. `[]` means no shortcut. Without a modifier only F keys are allowed. Changes apply as soon as the file is saved.

### Mouse buttons

Open the panel at the cursor with a mouse side button (or a button + modifier combo):

```json
{ "mouse": [{ "button": "back" }, { "button": "forward", "modifiers": ["option"] }] }
```

Needs the Accessibility permission. Matching clicks are swallowed, so they don't also trigger browser back/forward.

### Usage stats

Panel opens and app launches (with how each app was reached: pinned, grid, folder, or search query) are logged locally to `~/.config/menulauncher/usage.jsonl`. Nothing is uploaded. The launcher never reorders itself; the log exists so you or your agent can decide what to pin, hide, or file away. Set `"recordUsage": false` in the config to turn it off.

### Let your agent do it

Install the skill, then ask your agent something like "把开发相关的应用放进一个「开发」目录，隐藏国际象棋" or "按我最近一个月的使用情况整理一下固定区":

```sh
npx skills add ykai55/menubar-launcher
```

## Build

```sh
./build-app.sh       # build/MenuLauncher.app (host arch)
./make-dmg.sh        # universal build/MenuLauncher.dmg
./make-release.sh X.Y.Z   # tag, GitHub release, bump Homebrew cask
```
