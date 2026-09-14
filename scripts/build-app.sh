#!/bin/bash
# Builds YTerm in release mode and wraps it into build/YTerm.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="YTerm"
DISPLAY_NAME="YTerm"
BUNDLE_ID="com.yterm.app"
VERSION="${VERSION:-1.0.0}"
OUT_DIR="build"
APP_DIR="$OUT_DIR/$APP_NAME.app"

echo "▶ swift build -c release"
swift build -c release 2>&1 | tail -3
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "▶ 產生圖示"
ICONSET="$OUT_DIR/$APP_NAME.iconset"
rm -rf "$ICONSET"
if swift scripts/make-icon.swift "$ICONSET" >/dev/null 2>&1 && iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/$APP_NAME.icns" 2>/dev/null; then
  ICON_KEY="<key>CFBundleIconFile</key><string>$APP_NAME</string>"
else
  echo "  （略過圖示）"
  ICON_KEY=""
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_TW</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>rsync-enhance</string>
  <key>NSAppleEventsUsageDescription</key><string>用來在 Terminal.app 開啟 ssh 工作階段。</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.yterm.remote-items</string>
      <key>UTTypeDescription</key><string>YTerm remote items</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
  </array>
  $ICON_KEY
</dict>
</plist>
PLIST

echo "▶ codesign（ad-hoc）"
xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || echo "  （codesign 失敗，可忽略）"

echo "✅ 完成：$APP_DIR"
echo "   執行：open \"$APP_DIR\"    或拖到 /Applications"
