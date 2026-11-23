#!/usr/bin/env bash
set -euo pipefail

# Safe non-destructive coordinator upgrade helper: SlideCraft.app / Sidelark.app -> /Applications/Veypane.app
# - Quits any running com.slidecraft.app process cleanly
# - Moves any previous /Applications/SlideCraft.app, /Applications/Sidelark.app, or /Applications/Veypane.app into a timestamped backup
#   (NEVER deletes old app bundles and NEVER alters ~/Library/Application Support/SlideCraft or LaunchAgents)
# - Copies Veypane.app into /Applications/Veypane.app
# - Pass --launch to open /Applications/Veypane.app after installation.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="${SOURCE_APP:-$ROOT_DIR/Veypane.app}"
DEST_DIR="${DEST_DIR:-/Applications}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/SlideCraft-App-Backups}"
LAUNCH_AFTER=0

for arg in "$@"; do
    case "$arg" in
        --launch) LAUNCH_AFTER=1 ;;
    esac
done

if [ ! -d "$SOURCE_APP" ]; then
    echo "Error: $SOURCE_APP not found. Run ./scripts/bundle.sh first." >&2
    exit 1
fi

echo "==> Stopping any running com.slidecraft.app instance..."
osascript -e 'tell application id "com.slidecraft.app" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -f "SlideCraft.app/Contents/MacOS/SlideCraftApp" >/dev/null 2>&1 || true
pkill -f "Sidelark.app/Contents/MacOS/SlideCraftApp" >/dev/null 2>&1 || true
pkill -f "Veypane.app/Contents/MacOS/SlideCraftApp" >/dev/null 2>&1 || true
sleep 1

STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_ROOT"

if [ -d "$DEST_DIR/SlideCraft.app" ]; then
    BACKUP_LEGACY="$BACKUP_ROOT/SlideCraft-$STAMP.app"
    echo "==> Moving legacy $DEST_DIR/SlideCraft.app -> $BACKUP_LEGACY"
    mv "$DEST_DIR/SlideCraft.app" "$BACKUP_LEGACY"
    # Unregister backup path from LaunchServices so URL schemes & AppleEvents prefer /Applications/Veypane.app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$BACKUP_LEGACY" >/dev/null 2>&1 || true
fi

if [ -d "$DEST_DIR/Sidelark.app" ]; then
    BACKUP_PREV="$BACKUP_ROOT/Sidelark-$STAMP.app"
    echo "==> Moving previous $DEST_DIR/Sidelark.app -> $BACKUP_PREV"
    mv "$DEST_DIR/Sidelark.app" "$BACKUP_PREV"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$BACKUP_PREV" >/dev/null 2>&1 || true
fi

if [ -d "$DEST_DIR/Veypane.app" ]; then
    BACKUP_VEYPANE="$BACKUP_ROOT/Veypane-$STAMP.app"
    echo "==> Moving previous $DEST_DIR/Veypane.app -> $BACKUP_VEYPANE"
    mv "$DEST_DIR/Veypane.app" "$BACKUP_VEYPANE"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$BACKUP_VEYPANE" >/dev/null 2>&1 || true
fi

echo "==> Installing $SOURCE_APP -> $DEST_DIR/Veypane.app (preserving ~/Library/Application Support/SlideCraft)..."
cp -R "$SOURCE_APP" "$DEST_DIR/Veypane.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST_DIR/Veypane.app" >/dev/null 2>&1 || true

if [ "$LAUNCH_AFTER" -eq 1 ]; then
    echo "==> Launching $DEST_DIR/Veypane.app..."
    open "$DEST_DIR/Veypane.app"
else
    echo "==> Installed $DEST_DIR/Veypane.app (pass --launch to start)."
fi
