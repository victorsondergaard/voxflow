#!/bin/bash
# Builds VoxFlow with SwiftPM (Command Line Tools only — no Xcode needed)
# and wraps the binary in a proper .app bundle so macOS permissions work.
#
# Usage:
#   ./build.sh              build for this Mac's architecture
#   ./build.sh --universal  try to build a universal (Intel + Apple Silicon) binary
set -eu

cd "$(dirname "$0")"

UNIVERSAL=0
[ "${1:-}" = "--universal" ] && UNIVERSAL=1

if ! command -v swift >/dev/null 2>&1; then
    echo "✘ swift not found. Install Apple's Command Line Tools first:"
    echo "    xcode-select --install"
    exit 1
fi

echo "→ Building (release)…"
if [ "$UNIVERSAL" -eq 1 ]; then
    if swift build -c release --arch x86_64 --arch arm64 2>/dev/null; then
        BIN=".build/apple/Products/Release/VoxFlow"
        echo "✔ Universal binary built"
    else
        echo "! Universal build not supported by this toolchain — falling back to native build."
        swift build -c release
        BIN=".build/release/VoxFlow"
    fi
else
    swift build -c release
    BIN=".build/release/VoxFlow"
fi

if [ ! -f "$BIN" ]; then
    echo "✘ Build product not found at $BIN"
    exit 1
fi

APP="dist/VoxFlow.app"
echo "→ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/VoxFlow"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

echo "→ Ad-hoc code signing…"
codesign --force --deep --sign - "$APP"
codesign --verify "$APP" && echo "✔ Signature verified"

echo ""
echo "Done! → $APP"
echo ""
echo "Recommended: move it to Applications so permissions stick:"
echo "    mv -f dist/VoxFlow.app /Applications/"
echo "    open /Applications/VoxFlow.app"
echo ""
echo "First launch: grant Microphone + Accessibility when asked (see README)."
