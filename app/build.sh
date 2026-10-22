#!/bin/zsh
# Build Quill.app from Sources/ — no Xcode project required.
#
#   ./build.sh          compile, assemble and ad-hoc sign Quill.app
#   ./build.sh --zip    …and package it as Quill.app.zip (the release asset)
set -euo pipefail
cd "$(dirname "$0")"

APP=Quill.app
BIN=$APP/Contents/MacOS/Quill

# The version has one source of truth: npm/package.json. The bundle's marketing
# version is that semver without its prerelease tag (CFBundleShortVersionString
# must be dotted integers); the build number is the commit count of a full
# checkout, so it rises with every commit.
PKG_VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' ../npm/package.json | head -n 1)
if [[ -z "$PKG_VERSION" ]]; then
    echo "Could not read version from ../npm/package.json" >&2
    exit 1
fi
SHORT_VERSION=${PKG_VERSION%%-*}
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || true)
if [[ -z "$BUILD_NUMBER" || "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
    # A shallow clone or a source tarball cannot count commits; 1 is the
    # build number the shipped alpha.1 carries, so never release such a build.
    BUILD_NUMBER=1
    echo "warning: not a full git checkout; CFBundleVersion falls back to 1 (fine locally, do not release)" >&2
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling Quill $PKG_VERSION (build $BUILD_NUMBER)…"
swiftc \
    -O \
    -parse-as-library \
    -target arm64-apple-macos15.0 \
    Sources/*.swift \
    -o "$BIN"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Quill</string>
    <key>CFBundleDisplayName</key>       <string>Quill</string>
    <key>CFBundleIdentifier</key>        <string>com.quill.app</string>
    <key>CFBundleExecutable</key>        <string>Quill</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
    <key>CFBundleVersion</key>           <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>    <string>15.0</string>
    <key>LSUIElement</key>               <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key>  <string>© 2026 Pepper Research. MIT License.</string>
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

if [[ "${1:-}" == "--zip" ]]; then
    echo "Packaging…"
    rm -f "$APP.zip"
    # ditto keeps the code signature intact; --norsrc stops it from writing
    # ._ AppleDouble entries for extended attributes (the alpha.1 zip has them).
    ditto -c -k --keepParent --norsrc "$APP" "$APP.zip"
    echo "Packaged $PWD/$APP.zip"
    shasum -a 256 "$APP.zip"
fi
