#!/bin/bash
# 发版：./make-release.sh 0.3.0
# 写 VERSION → 打 DMG/zip → 打 tag 推送 → 建 GitHub Release → 更新 Homebrew tap 里的 cask
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$1"
REPO=ykai55/menubar-launcher
TAP=ykai55/homebrew-tap

echo "$VERSION" > VERSION
./make-dmg.sh
rm -f build/MenuLauncher.zip
ditto -c -k --keepParent build/MenuLauncher.app build/MenuLauncher.zip

git add VERSION
git commit -m "Release v$VERSION" || true
git tag "v$VERSION"
git push origin HEAD "v$VERSION"

gh release create "v$VERSION" build/MenuLauncher.dmg build/MenuLauncher.zip \
    --repo "$REPO" --title "v$VERSION" --notes-file - <<EOF
## 安装

\`\`\`sh
brew install --cask ykai55/tap/menulauncher
\`\`\`

更新：\`brew upgrade --cask menulauncher\`

也可以下载下面的 MenuLauncher.dmg，把应用拖进「应用程序」。应用没有经过 Apple 公证，第一次打开前执行：

\`\`\`sh
xattr -dr com.apple.quarantine /Applications/MenuLauncher.app
\`\`\`

需要 macOS 15 或更高版本，同时支持 Apple 芯片和 Intel。
EOF

# 更新 cask 的版本号和校验和
SHA=$(shasum -a 256 build/MenuLauncher.zip | cut -d' ' -f1)
TMP=$(mktemp -d)
gh repo clone "$TAP" "$TMP" -- --quiet
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TMP/Casks/menulauncher.rb"
git -C "$TMP" commit -am "menulauncher $VERSION"
git -C "$TMP" push --quiet
rm -rf "$TMP"
echo "Released v$VERSION"
