#!/usr/bin/env bash
set -euo pipefail

# Produces Veypane.app and Veypane.zip in the repository root (or $OUTPUT_DIR) without launching the app.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="${CONFIGURATION:-release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR}"
APP_BUNDLE="$OUTPUT_DIR/Veypane.app"
APP_ARCHIVE="$OUTPUT_DIR/Veypane.zip"

echo "==> Building Veypane ($CONFIG)..."
cd "$ROOT_DIR"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP_BUNDLE" "$APP_ARCHIVE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

if [ ! -f "$ROOT_DIR/Assets/AppIcon/Veypane.icns" ]; then
    swift "$ROOT_DIR/scripts/generate-icon.swift"
fi
cp "$ROOT_DIR/Assets/AppIcon/Veypane.icns" "$APP_BUNDLE/Contents/Resources/Veypane.icns"

cp "$BIN_DIR/VeypaneApp" "$APP_BUNDLE/Contents/MacOS/VeypaneApp"
cp "$BIN_DIR/veypanectl" "$APP_BUNDLE/Contents/MacOS/veypanectl"
chmod +x \
    "$APP_BUNDLE/Contents/MacOS/VeypaneApp" \
    "$APP_BUNDLE/Contents/MacOS/veypanectl"

# Copy SwiftPM resource bundles (Veypane_VeypaneCore.bundle with en & zh-Hans Localizable.strings and Veypane.icns)
shopt -s nullglob
for res_bundle in "$BIN_DIR"/Veypane_*.bundle; do
    bundle_name="$(basename "$res_bundle")"
    dest_bundle="$APP_BUNDLE/Contents/Resources/$bundle_name"
    cp -R "$res_bundle" "$dest_bundle"
    if [ -d "$dest_bundle/zh-hans.lproj" ]; then
        mv "$dest_bundle/zh-hans.lproj" "$dest_bundle/zh-Hans.tmp.lproj"
        mv "$dest_bundle/zh-Hans.tmp.lproj" "$dest_bundle/zh-Hans.lproj"
    fi
    if [ -d "$dest_bundle/en.lproj" ]; then
        cp -R "$dest_bundle/en.lproj" "$APP_BUNDLE/Contents/Resources/en.lproj"
    fi
    if [ -d "$dest_bundle/zh-Hans.lproj" ]; then
        cp -R "$dest_bundle/zh-Hans.lproj" "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj"
    fi
done
shopt -u nullglob

cat > "$APP_BUNDLE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>CFBundleDisplayName</key>
    <string>Veypane</string>
    <key>CFBundleExecutable</key>
    <string>VeypaneApp</string>
    <key>CFBundleIconFile</key>
    <string>Veypane</string>
    <key>CFBundleIconName</key>
    <string>Veypane</string>
    <key>CFBundleIdentifier</key>
    <string>com.veypane.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Veypane</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.10</string>
    <key>CFBundleVersion</key>
    <string>13</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.veypane.urlscheme</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>veypane</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

touch "$APP_BUNDLE"
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$APP_ARCHIVE"

echo "==> Created $APP_BUNDLE"
echo "==> Created $APP_ARCHIVE"
