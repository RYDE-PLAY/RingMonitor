#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_NAME="RingMonitor"
APP_DIR="$ROOT_DIR/$APP_NAME.app"
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
RELEASE_DIR="$ROOT_DIR/.build/${BUILD_ARCH}-apple-macosx/release"
APP_VERSION="${APP_VERSION:-}"

swift build \
  --package-path "$ROOT_DIR" \
  -c release \
  -Xswiftc -Osize \
  -Xswiftc -gnone

if [[ ! -f "$RELEASE_DIR/$APP_NAME" ]]; then
    echo "找不到 release 可执行文件：$RELEASE_DIR/$APP_NAME" >&2
    exit 1
fi

if [[ -d "$APP_DIR" ]]; then
    rm -rf "$APP_DIR"
fi

mkdir -p "$APP_DIR/Contents/MacOS"
cp "$RELEASE_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

if [[ -n "$APP_VERSION" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleShortVersionString $APP_VERSION" \
        "$APP_DIR/Contents/Info.plist"
fi

strip -x "$APP_DIR/Contents/MacOS/$APP_NAME"
codesign --force --deep --sign - "$APP_DIR"

echo "已生成：$APP_DIR"
du -sh "$APP_DIR"
