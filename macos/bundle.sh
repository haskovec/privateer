#!/usr/bin/env bash
#
# Create a macOS .app bundle for Privateer.
#
# Usage:
#   ./macos/bundle.sh [--universal]
#
# Without --universal: builds for the native architecture only.
# With --universal: builds both x86_64 and aarch64, then creates a universal binary via lipo.
#
# Output: zig-out/Privateer.app/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_DIR="$PROJECT_DIR/zig-out/Privateer.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

UNIVERSAL=false
if [[ "${1:-}" == "--universal" ]]; then
    UNIVERSAL=true
fi

echo "==> Building Privateer macOS app bundle..."

# Clean previous bundle
rm -rf "$APP_DIR"

# Create bundle structure
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES"

# Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"

if $UNIVERSAL; then
    echo "==> Building x86_64 binary..."
    zig build -Dtarget=x86_64-macos -Doptimize=ReleaseFast --prefix "$PROJECT_DIR/zig-out/x86_64" 2>&1

    echo "==> Building aarch64 binary..."
    zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast --prefix "$PROJECT_DIR/zig-out/aarch64" 2>&1

    echo "==> Creating universal binary with lipo..."
    lipo -create \
        "$PROJECT_DIR/zig-out/x86_64/bin/privateer" \
        "$PROJECT_DIR/zig-out/aarch64/bin/privateer" \
        -output "$MACOS_DIR/privateer"

    # Clean up intermediate builds
    rm -rf "$PROJECT_DIR/zig-out/x86_64" "$PROJECT_DIR/zig-out/aarch64"
else
    echo "==> Building native binary..."
    zig build -Doptimize=ReleaseFast 2>&1
    cp "$PROJECT_DIR/zig-out/bin/privateer" "$MACOS_DIR/privateer"
fi

chmod +x "$MACOS_DIR/privateer"

# Copy icon if it exists
if [[ -f "$SCRIPT_DIR/privateer.icns" ]]; then
    cp "$SCRIPT_DIR/privateer.icns" "$RESOURCES/privateer.icns"
fi

# Embed game data if PRIVATEER_DATA is set and contains GAME.DAT
DATA_SOURCE="${PRIVATEER_DATA:-}"
if [[ -z "$DATA_SOURCE" && -f "$PROJECT_DIR/privateer.json" ]]; then
    # Try to read data_dir from privateer.json
    DATA_SOURCE=$(python3 -c "import json; print(json.load(open('$PROJECT_DIR/privateer.json'))['data_dir'])" 2>/dev/null || true)
fi

if [[ -n "$DATA_SOURCE" && -f "$DATA_SOURCE/GAME.DAT" ]]; then
    echo "==> Embedding game data from $DATA_SOURCE..."
    mkdir -p "$RESOURCES/data"
    cp "$DATA_SOURCE/GAME.DAT" "$RESOURCES/data/GAME.DAT"
    echo "    GAME.DAT included in bundle ($(du -h "$RESOURCES/data/GAME.DAT" | cut -f1) )"
else
    echo "==> No GAME.DAT found. Set PRIVATEER_DATA to embed game data in the bundle."
    echo "    The app will look for data in the current directory or via --data-dir at runtime."
fi

echo "==> Bundle created: $APP_DIR"
echo "    Run with: open $APP_DIR"
