#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/Backup & Eject.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MASTER_ICON="$ROOT_DIR/.build/AppIcon-1024.png"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
SRGB_PROFILE="/System/Library/ColorSync/Profiles/sRGB Profile.icc"

cd "$ROOT_DIR"

ARCHITECTURE_BINARIES=()
for architecture in arm64 x86_64; do
    scratch_path="$ROOT_DIR/.build/$architecture"
    triple="${architecture}-apple-macosx14.0"

    swift build \
        -c release \
        --product BackupAndEject \
        --scratch-path "$scratch_path" \
        --triple "$triple" \
        -Xswiftc -gnone

    bin_path="$(swift build \
        -c release \
        --scratch-path "$scratch_path" \
        --triple "$triple" \
        --show-bin-path)"
    ARCHITECTURE_BINARIES+=("$bin_path/BackupAndEject")
done

rm -rf "$APP_BUNDLE" "$MASTER_ICON" "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR"

xcrun lipo -create \
    "${ARCHITECTURE_BINARIES[@]}" \
    -output "$MACOS_DIR/BackupAndEject"
chmod 755 "$MACOS_DIR/BackupAndEject"
strip -S "$MACOS_DIR/BackupAndEject"
cp "$ROOT_DIR/App/Info.plist" "$CONTENTS_DIR/Info.plist"

swift "$ROOT_DIR/Tools/MakeIcon.swift" "$MASTER_ICON"

if [[ ! -f "$SRGB_PROFILE" ]]; then
    echo "Could not find the standard macOS sRGB color profile." >&2
    exit 1
fi

sips -m "$SRGB_PROFILE" "$MASTER_ICON" >/dev/null

for point_size in 16 32 128 256 512; do
    pixel_size="$point_size"
    retina_size="$((point_size * 2))"

    sips -z "$pixel_size" "$pixel_size" "$MASTER_ICON" \
        --out "$ICONSET_DIR/icon_${point_size}x${point_size}.png" >/dev/null
    sips -z "$retina_size" "$retina_size" "$MASTER_ICON" \
        --out "$ICONSET_DIR/icon_${point_size}x${point_size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"

if ! sips -g profile "$RESOURCES_DIR/AppIcon.icns" | grep -q "sRGB"; then
    echo "Generated app icon is not using the standard sRGB profile." >&2
    exit 1
fi

plutil -lint "$CONTENTS_DIR/Info.plist"
xattr -cr "$APP_BUNDLE"
codesign --force --deep --sign - \
    --identifier com.aaronfish1labs.backupandeject \
    "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "$APP_BUNDLE"
