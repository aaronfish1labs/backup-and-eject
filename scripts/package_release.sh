#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/Backup & Eject.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT_DIR/App/Info.plist")"
ARCHIVE="$DIST_DIR/Backup-and-Eject-v${VERSION}-macOS.zip"
CHECKSUM="$ARCHIVE.sha256"

"$ROOT_DIR/scripts/build_app.sh" >/dev/null

rm -f "$ARCHIVE" "$CHECKSUM"
ditto -c -k --keepParent \
    --norsrc --noextattr --noqtn --noacl \
    "$APP_BUNDLE" "$ARCHIVE"
(
    cd "$DIST_DIR"
    shasum -a 256 "$(basename "$ARCHIVE")"
) > "$CHECKSUM"

echo "$ARCHIVE"
echo "$CHECKSUM"
