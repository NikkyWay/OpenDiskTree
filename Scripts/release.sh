#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"
"$ROOT_DIR/Scripts/build-app.sh"

VERSION=${1:-dev}
ARCHIVE="$ROOT_DIR/dist/OpenDiskTree-$VERSION-arm64.zip"
DISK_IMAGE="$ROOT_DIR/dist/OpenDiskTree-$VERSION-arm64.dmg"
CHECKSUMS="$ROOT_DIR/dist/OpenDiskTree-$VERSION-SHA256SUMS.txt"

rm -f "$ARCHIVE" "$DISK_IMAGE" "$CHECKSUMS"
ditto -c -k --sequesterRsrc --keepParent "$ROOT_DIR/dist/OpenDiskTree.app" "$ARCHIVE"
hdiutil create \
    -volname "OpenDiskTree $VERSION" \
    -srcfolder "$ROOT_DIR/dist/OpenDiskTree.app" \
    -format UDZO \
    -ov \
    "$DISK_IMAGE"

(
    cd "$ROOT_DIR/dist"
    shasum -a 256 "$(basename "$ARCHIVE")" "$(basename "$DISK_IMAGE")"
) > "$CHECKSUMS"

echo "Created $ARCHIVE"
echo "Created $DISK_IMAGE"
echo "Created $CHECKSUMS"
