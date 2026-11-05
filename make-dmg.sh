#!/bin/bash
# 打包成可分发的 build/MenuLauncher.dmg：通用二进制（Apple 芯片 + Intel），带「拖到 Applications」快捷方式
set -euo pipefail
cd "$(dirname "$0")"

./build-app.sh

# 分别编两个架构再合并。build-app.sh 产出的是本机架构，这里替换成通用二进制
APP=build/MenuLauncher.app
for arch in arm64 x86_64; do
    swift build -c release --build-system native --triple "$arch-apple-macosx15.0"
done
lipo -create \
    "$(swift build -c release --build-system native --triple arm64-apple-macosx15.0 --show-bin-path)/MenuLauncher" \
    "$(swift build -c release --build-system native --triple x86_64-apple-macosx15.0 --show-bin-path)/MenuLauncher" \
    -output "$APP/Contents/MacOS/MenuLauncher"
# ad-hoc 签名默认的签名要求是二进制的 cdhash，每次编译都变，系统里的辅助功能授权就对不上了
# （设置里显示已开，实际不生效，每次启动还会再弹授权）。改成按 bundle id 匹配，重新编译后授权仍然有效
codesign --force --sign - -r='designated => identifier "local.menulauncher"' "$APP"

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG=build/MenuLauncher.dmg
rm -f "$DMG"
hdiutil create -volname MenuLauncher -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
