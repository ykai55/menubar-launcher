# MenuLauncher

A macOS menu bar dropdown app launcher. Press ⌥Space or click the menu bar icon to get an icon grid with a fixed layout: 固定 (pinned) apps first, then folders, then A–Z by name (Chinese names sort by pinyin). There is no usage-based sorting, so apps stay where you remember them.

- Type to search by name, pinyin (`weixin`), initials (`wx`, `vsc`)
- Click a section header to jump to a letter
- Pin, hide, and group apps into nested folders
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

App references can be bundle ids, paths, or display names. Helper commands (the cask links `menulauncher` into your PATH):

```sh
menulauncher --list-apps   # installed apps as JSON, with bundle ids and current state
menulauncher --check       # validate the config
```

### Let your agent do it

Install the skill, then ask your agent something like "把开发相关的应用放进一个「开发」目录，隐藏国际象棋":

```sh
npx skills add ykai55/menubar-launcher
```

## Build

```sh
./build-app.sh       # build/MenuLauncher.app (host arch)
./make-dmg.sh        # universal build/MenuLauncher.dmg
./make-release.sh X.Y.Z   # tag, GitHub release, bump Homebrew cask
```
