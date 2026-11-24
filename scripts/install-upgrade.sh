#!/usr/bin/env bash
set -euo pipefail

# Safe non-destructive upgrade helper: installs Veypane.app into /Applications/Veypane.app
# - Quits any running com.veypane.app process cleanly
# - Moves any previous /Applications/Veypane.app into a timestamped backup
#   (NEVER deletes old app bundles and NEVER alters ~/Library/Application Support/Veypane or LaunchAgents)
# - Copies Veypane.app into /Applications/Veypane.app
# - Pass --launch to open /Applications/Veypane.app after installation.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="${SOURCE_APP:-$ROOT_DIR/Veypane.app}"
DEST_DIR="${DEST_DIR:-/Applications}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/Veypane-App-Backups}"
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

echo "==> Stopping any running com.veypane.app instance..."
osascript -e 'tell application id "com.veypane.app" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -f "Veypane.app/Contents/MacOS/VeypaneApp" >/dev/null 2>&1 || true
sleep 1

STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_ROOT"

if [ -d "$DEST_DIR/Veypane.app" ]; then
    BACKUP_VEYPANE="$BACKUP_ROOT/Veypane-$STAMP.app"
    echo "==> Moving previous $DEST_DIR/Veypane.app -> $BACKUP_VEYPANE"
    mv "$DEST_DIR/Veypane.app" "$BACKUP_VEYPANE"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$BACKUP_VEYPANE" >/dev/null 2>&1 || true
fi

echo "==> Installing $SOURCE_APP -> $DEST_DIR/Veypane.app (preserving ~/Library/Application Support/Veypane)..."
cp -R "$SOURCE_APP" "$DEST_DIR/Veypane.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST_DIR/Veypane.app" >/dev/null 2>&1 || true

if [ "$LAUNCH_AFTER" -eq 1 ]; then
    echo "==> Launching $DEST_DIR/Veypane.app..."
    open "$DEST_DIR/Veypane.app"
else
    echo "==> Installed $DEST_DIR/Veypane.app (pass --launch to start)."
fi
