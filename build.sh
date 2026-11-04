#!/bin/bash
# TouchBarLyrics 构建:编译 → 组装 .app → ad-hoc 签名
set -euo pipefail
cd "$(dirname "$0")"

# 产出固定安装到用户主目录,避免和工作区缓存目录耦合
APP="/Users/lumingyuan/TouchBarLyrics.app"
OUT="$APP/Contents/MacOS"
PLIST="$APP/Contents/Info.plist"

clang -fobjc-arc -O2 -Wall -mmacosx-version-min=13.0 \
    -framework AppKit -framework CoreGraphics -framework QuartzCore \
    src/main.m src/TBPrivate.m src/TBMediaRemote.m src/TBLyrics.m src/TBTouchBarController.m \
    -o /tmp/TouchBarLyrics.bin

rm -rf "$APP"
mkdir -p "$OUT"
mv /tmp/TouchBarLyrics.bin "$OUT/TouchBarLyrics"

cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TouchBarLyrics</string>
    <key>CFBundleIdentifier</key><string>com.github.alty.touchbarlyrics</string>
    <key>CFBundleName</key><string>TouchBarLyrics</string>
    <key>CFBundleDisplayName</key><string>TouchBarLyrics</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>个人学习用途</string>
</dict>
</plist>
EOF

codesign --force -s - "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"
echo "构建完成: $APP"
