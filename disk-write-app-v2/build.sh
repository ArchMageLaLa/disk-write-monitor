#!/bin/bash
# 编译磁盘写入量 App，并打成 dmg。
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
APP_NAME="DiskWrites"
DISPLAY_NAME="磁盘写入量"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$DIST/$DISPLAY_NAME.app"
SMARTCTL="${SMARTCTL:-/usr/local/sbin/smartctl}"
COPYING="${COPYING:-/usr/local/share/doc/smartmontools/COPYING}"

rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$DIST"

echo "==> 编译 arm64"
swiftc -parse-as-library -O \
  -module-cache-path "$BUILD/modcache" \
  -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AppKit \
  src/DiskWrites.swift -o "$BUILD/$APP_NAME-arm64"

echo "==> 编译 x86_64"
swiftc -parse-as-library -O \
  -module-cache-path "$BUILD/modcache" \
  -target x86_64-apple-macos13.0 \
  -framework SwiftUI -framework AppKit \
  src/DiskWrites.swift -o "$BUILD/$APP_NAME-x86_64"

echo "==> 合并为通用二进制"
lipo -create "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64" -output "$BUILD/$APP_NAME"
lipo -info "$BUILD/$APP_NAME"

echo "==> 组装 .app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp src/Info.plist "$APP/Contents/Info.plist"
cp src/NOTICE.txt "$APP/Contents/Resources/NOTICE.txt"

if [ -x "$SMARTCTL" ]; then
  cp "$SMARTCTL" "$APP/Contents/Resources/smartctl"
  chmod 755 "$APP/Contents/Resources/smartctl"
  echo "    已内置 smartctl：$(lipo -info "$APP/Contents/Resources/smartctl" | sed 's/.*are: //')"
else
  echo "!! 找不到 $SMARTCTL，将依赖用户自己安装的 smartmontools"
fi

if [ -f "$COPYING" ]; then
  cp "$COPYING" "$APP/Contents/Resources/LICENSE-smartmontools.txt"
fi

if [ -f "resources/AppIcon.icns" ]; then
  cp "resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> 临时签名（ad-hoc，仅让 Apple Silicon 能运行）"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2

echo "==> 打包 dmg"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/应用程序"
if [ -f first-run.txt ]; then cp first-run.txt "$STAGE/第一次使用请看这里.txt"; fi
if ! hdiutil create -quiet -volname "$DISPLAY_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$DISPLAY_NAME.dmg"; then
  echo "!! 创建 dmg 失败（沙箱里常见），请在普通终端里重新运行本脚本，或手动执行 hdiutil create"
fi
cp first-run.txt "$DIST/第一次使用请看这里.txt" 2>/dev/null || true

echo
echo "完成："
ls -lh "$DIST"
