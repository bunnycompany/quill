#!/bin/zsh
# Build Quill.app from Sources/ — no Xcode project required.
set -euo pipefail
cd "$(dirname "$0")"

APP=Quill.app
BIN=$APP/Contents/MacOS/Quill

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc \
    -O \
    -parse-as-library \
    -target arm64-apple-macos15.0 \
    Sources/*.swift \
    -o "$BIN"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Quill</string>
    <key>CFBundleDisplayName</key>       <string>Quill</string>
    <key>CFBundleIdentifier</key>        <string>com.quill.app</string>
    <key>CFBundleExecutable</key>        <string>Quill</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>15.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Quill records your meetings with the microphone. Audio never leaves this Mac.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Quill transcribes your meetings entirely on-device.</string>
</dict>
</plist>
PLIST

echo "Signing (ad-hoc)…"
codesign --force --sign - "$APP"

echo "Built $PWD/$APP"
