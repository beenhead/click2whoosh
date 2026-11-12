#!/bin/sh
# Builds both front-ends:
#   ./click2whoosh       terminal version
#   ./click2whoosh.app   menu bar app
set -e
cd "$(dirname "$0")"

# CLI (Info.plist embedded so macOS shows a Bluetooth usage string)
swiftc -O Sources/Core/*.swift Sources/CLI/main.swift -o click2whoosh \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
echo "Built ./click2whoosh"

# Menu bar app
APP=click2whoosh.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library Sources/Core/*.swift Sources/App/App.swift -o "$APP/Contents/MacOS/click2whoosh"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.click2whoosh</string>
  <key>CFBundleName</key><string>click2whoosh</string>
  <key>CFBundleExecutable</key><string>click2whoosh</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Connects to your Zwift Click controller.</string>
</dict>
</plist>
EOF
# Stable designated requirement: macOS keeps the Accessibility grant across rebuilds.
codesign --force --sign - -r='designated => identifier "local.click2whoosh"' "$APP" >/dev/null
echo "Built ./$APP"
