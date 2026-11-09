# MenuLauncher

English | [简体中文](README.zh-CN.md)

A macOS menu bar dropdown app launcher. Press ⌥Space or click the menu bar icon to get an icon grid with a fixed layout. Choose a browse mode in **Settings → General**, or press Tab while browsing: **Custom** shows pinned apps, a divider, then your folders mixed with unfiled apps, without section titles or an index. You can drag folders and apps to reorder them within their section. **A–Z** shows Pinned then visible apps by name (Chinese names sort by pinyin), ignoring folder hierarchy. There is no usage-based sorting, so apps stay where you remember them.

- Type to search by name, pinyin (`weixin`), initials (`wx`, `vsc`)
- Hover over an app or folder to see a hand cursor. Keyboard navigation shows a thin outline; moving the mouse or scrolling hides it.
- In sorted mode, click a section header to jump to a letter
- Pin and hide apps, organize them into nested folders, or hide whole folders
- Open the hidden area with the eye-slash button beside search to browse, launch, and restore hidden items
- Choose English, Simplified Chinese, or your system language in Settings
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

Use the right-click menu on an app (Pin to top / Hide / Remove from folder), or edit `~/.config/menulauncher/config.json`. The app reloads the file on save:

```json
{
  "pinned": ["com.apple.Safari"],
  "hidden": ["com.apple.Chess"],
  "folders": [
    { "name": "Development", "apps": ["com.apple.Terminal"], "folders": [{ "name": "Databases", "apps": [] }] }
  ]
}
```

Right-click a folder and choose **Hide folder**, or add `"hidden": true` to that folder object. This hides the folder, its descendants, and their apps from ordinary browsing and search, including pinned shortcuts. The hidden area lists hidden folders and individually hidden apps; search there covers hidden apps. Use **Unhide folder** or **Unhide** in its right-click menus to restore items. Apps hidden through a folder become visible when that folder is restored; independently hidden apps keep their own hidden setting. Existing folder membership and ordering are preserved.

In the hidden area, the back bar, Esc, Backspace, or a blank-area click returns one level. Closing the panel exits the hidden area.

In custom mode, folder centers and edges have different drag actions. Hold over the center for about 0.4 seconds, then release after the **Move inside** highlight to move inside. Near an edge, an insertion line shows where the item will go; hold for about 0.18 seconds to preview reordering, or release immediately to insert. Briefly crossing an edge does not push the folder away. Moving away cancels the pending action. Items moved inside are appended after existing contents. Pinned shortcuts remain pinned, and folders keep their subtrees. A folder cannot move into itself, its descendants, or a destination with a child folder of the same name.

App references can be bundle ids, paths, or display names. Helper commands (the cask links `menulauncher` into your PATH):

```sh
menulauncher --list-apps   # installed apps as JSON, with bundle ids and current state
menulauncher --check       # validate the config
menulauncher --stats 30    # usage summary for the last 30 days (JSON)
```

## Settings

Click the gear beside search, right-click the menu bar icon and choose **Settings…**, or press **⌘,** while the panel is open. `menulauncher --settings` opens settings when launching the app.

Settings opens on the same display as the launcher panel, or on the display under the pointer when the panel is closed.

- **General**: choose a language and browse mode (Custom / A–Z), enable or disable local usage recording, open the JSON config, and rescan installed apps.
- **Shortcuts**: edit keyboard shortcuts (one per line), add or remove mouse triggers, and open Accessibility settings.

Click **Save** or press **⌘S** to apply changes immediately. **Cancel** discards unsaved changes. Invalid shortcuts and mouse bindings are rejected; keyboard registration failures are shown in the window. Saving merges only the preferences you changed into the latest config, preserving external changes to folders, pins, hidden items, and ordering.

Browse mode is remembered in macOS preferences, along with each mode's scroll position.

The optional `language` field accepts `"system"` (default), `"en"`, or `"zh-Hans"`. System mode chooses Chinese or English from your preferred languages and falls back to English. Language changes affect the launcher interface and CLI messages; installed app names follow macOS, and custom folder names remain as entered. Existing configs work without adding this field.

### Keyboard shortcuts

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

Install the skill, then ask your agent something like "Move development apps into a Development folder and hide Chess" or "Organize my pinned apps based on the last month of usage":

```sh
npx skills add ykai55/menubar-launcher
```

## Build

```sh
./build-app.sh       # build/MenuLauncher.app (host arch)
./make-dmg.sh        # universal build/MenuLauncher.dmg
./make-release.sh X.Y.Z   # optionally set a version floor and push main
```

## Continuous deployment

Every push to `main` runs the tests, builds universal DMG/ZIP packages and
`menulauncher-skill.zip`, publishes a GitHub Release, and updates the Homebrew cask.
Pushes are serialized; queued commits superseded by a newer main commit are skipped.
The workflow can also be started manually from Actions on main.

The release version is the greater of `VERSION` and the highest existing release
tag's next patch version. The workflow tags the exact source commit without
writing back to main. To start a new minor or major version, change `VERSION`
before pushing, or run `./make-release.sh X.Y.Z`.

Re-running a failed workflow reuses its tag. An already published release keeps
its original archives; the workflow downloads its ZIP to retry the Homebrew update.
The tap requires the repository secret `TAP_DEPLOY_KEY` with write access to
`ykai55/homebrew-tap`.
