#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$ROOT_DIR/.build/release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/OpenDiskTree.app"

cd "$ROOT_DIR"
swift build -c release --product OpenDiskTree

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/OpenDiskTree" "$APP_DIR/Contents/MacOS/OpenDiskTree"
cp "$ROOT_DIR/Support/Info.plist" "$APP_DIR/Contents/Info.plist"

if [ -d "$BUILD_DIR/OpenDiskTree_OpenDiskTreeApp.bundle" ]; then
    cp -R "$BUILD_DIR/OpenDiskTree_OpenDiskTreeApp.bundle" "$APP_DIR/Contents/Resources/"
fi
cp -R "$ROOT_DIR/Sources/OpenDiskTreeApp/Resources/en.lproj" "$APP_DIR/Contents/Resources/"
cp -R "$ROOT_DIR/Sources/OpenDiskTreeApp/Resources/ru.lproj" "$APP_DIR/Contents/Resources/"

codesign --force --sign - --timestamp=none "$APP_DIR"
echo "Built $APP_DIR"
