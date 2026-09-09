#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_NAME="RingMonitor"
APP_DIR="$ROOT_DIR/$APP_NAME.app"
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
RELEASE_DIR="$ROOT_DIR/.build/${BUILD_ARCH}-apple-macosx/release"
APP_VERSION="${APP_VERSION:-}"
ICON_SOURCE="$ROOT_DIR/docs/figma-icon.png"
ICON_BUILD_DIR="$ROOT_DIR/.build/$BUILD_ARCH-apple-macosx/RingMonitor.iconset"
ICON_FILE="$ROOT_DIR/.build/$BUILD_ARCH-apple-macosx/RingMonitor.icns"

swift build \
  --package-path "$ROOT_DIR" \
  -c release \
  -Xswiftc -Osize \
  -Xswiftc -gnone

if [[ ! -f "$RELEASE_DIR/$APP_NAME" ]]; then
    echo "找不到 release 可执行文件：$RELEASE_DIR/$APP_NAME" >&2
    exit 1
fi

if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "找不到应用图标源文件：$ICON_SOURCE" >&2
    exit 1
fi

# Generate the standard macOS iconset from the deterministic Figma export.
# sips and iconutil are available on the macOS build runner, so releases do
# not depend on a third-party SVG renderer.
rm -rf "$ICON_BUILD_DIR"
mkdir -p "$ICON_BUILD_DIR"

render_icon() {
    local size="$1"
    local filename="$2"
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICON_BUILD_DIR/$filename" >/dev/null
}

render_icon 16 "icon_16x16.png"
render_icon 32 "icon_16x16@2x.png"
render_icon 32 "icon_32x32.png"
render_icon 64 "icon_32x32@2x.png"
render_icon 128 "icon_128x128.png"
render_icon 256 "icon_128x128@2x.png"
render_icon 256 "icon_256x256.png"
render_icon 512 "icon_256x256@2x.png"
render_icon 512 "icon_512x512.png"
render_icon 1024 "icon_512x512@2x.png"

iconutil -c icns "$ICON_BUILD_DIR" -o "$ICON_FILE"

if [[ -d "$APP_DIR" ]]; then
    rm -rf "$APP_DIR"
fi

mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$RELEASE_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ICON_FILE" "$APP_DIR/Contents/Resources/RingMonitor.icns"

if [[ -n "$APP_VERSION" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleShortVersionString $APP_VERSION" \
        "$APP_DIR/Contents/Info.plist"
fi

strip -x "$APP_DIR/Contents/MacOS/$APP_NAME"
codesign --force --deep --sign - "$APP_DIR"

echo "已生成：$APP_DIR"
du -sh "$APP_DIR"
