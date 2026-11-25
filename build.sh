#!/bin/zsh
# ClaudeBell.app 을 빌드해 ~/Applications 에 설치한다. 소스를 고친 뒤 다시 실행하면 된다.
set -euo pipefail

DIR="${0:A:h}"
APP="$HOME/Applications/ClaudeBell.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/ClaudeBell" "$DIR"/src/*.swift -framework AppKit -framework AVFoundation -framework SwiftUI

# 앱 아이콘 (🔔). 한 번 만들어 두고 재사용한다 — 다시 만들려면 AppIcon.icns 를 지운다
if [[ ! -f "$DIR/AppIcon.icns" ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift "$DIR/make-icon.swift" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$DIR/AppIcon.icns"
fi
cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ClaudeBell</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>local.claudebell</string>
  <key>CFBundleName</key><string>ClaudeBell</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP"
