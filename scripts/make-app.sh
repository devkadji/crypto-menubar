#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) release executable and wrap it in a
# macOS .app bundle. Output: CryptoMenubar.app in the project root.
#
# Usage:  ./scripts/make-app.sh           # universal binary (default)
#         ./scripts/make-app.sh native    # only the host architecture

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="CryptoMenubar"
APP_DISPLAY_NAME="Crypto Menubar"
BUNDLE_ID="io.github.devkadji.cryptomenubar"
VERSION="2.1"
BUILD="13"
MIN_MACOS="14.0"
MODE="${1:-universal}"

if [[ "$MODE" == "universal" ]]; then
    echo "==> Building arm64"
    swift build -c release --triple arm64-apple-macosx${MIN_MACOS}
    echo "==> Building x86_64"
    swift build -c release --triple x86_64-apple-macosx${MIN_MACOS}

    ARM64=".build/arm64-apple-macosx/release/${APP_NAME}"
    X86_64=".build/x86_64-apple-macosx/release/${APP_NAME}"
    [[ -f "$ARM64"  ]] || { echo "missing $ARM64"; exit 1; }
    [[ -f "$X86_64" ]] || { echo "missing $X86_64"; exit 1; }

    echo "==> lipo-ing into universal binary"
    BIN=".build/release/${APP_NAME}-universal"
    mkdir -p .build/release
    lipo -create "$ARM64" "$X86_64" -output "$BIN"
    lipo -info "$BIN"
else
    echo "==> Building native architecture only"
    swift build -c release
    BIN=".build/release/${APP_NAME}"
    [[ -f "$BIN" ]] || { echo "missing $BIN"; exit 1; }
fi

APP="${APP_NAME}.app"
echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_DISPLAY_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP" >/dev/null

echo
echo "Built ./${APP}"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/${APP_NAME}")"
echo
echo "To install locally:  mv ${APP} /Applications/   (or drag in Finder)"
echo "To package for friends:  ./scripts/make-dist.sh"
