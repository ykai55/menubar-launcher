#!/bin/bash
# 构建 release 并打包成 MenuLauncher.app（放在 build/ 下）
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-$(cat VERSION)}"

swift build -c release --build-system native
BIN="$(swift build -c release --build-system native --show-bin-path)/MenuLauncher"

APP=build/MenuLauncher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MenuLauncher"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MenuLauncher</string>
    <key>CFBundleIdentifier</key><string>local.menulauncher</string>
    <key>CFBundleName</key><string>MenuLauncher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <!-- 声明支持的语言。没有这项时本应用被视为只有英文，
         FileManager.displayName 会按英文返回其他应用的名字（"系统设置"变成 "System Settings"） -->
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>zh-Hant</string>
        <string>en</string>
    </array>
</dict>
</plist>
EOF

# ad-hoc 签名默认的签名要求是二进制的 cdhash，每次编译都变，系统里的辅助功能授权就对不上了
# （设置里显示已开，实际不生效，每次启动还会再弹授权）。改成按 bundle id 匹配，重新编译后授权仍然有效
codesign --force --sign - -r='designated => identifier "local.menulauncher"' "$APP"
echo "Built $APP"
