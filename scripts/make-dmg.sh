#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="dist/Project Switcher.app"
if [[ ! -d "$APP" ]]; then
  echo "找不到 $APP，请先运行: make app" >&2
  exit 1
fi

VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "0.1.0"
)"
DMG_NAME="Project-Switcher-${VERSION}"
STAGE=".build/dmg-stage"
DMG_TMP=".build/${DMG_NAME}-tmp.dmg"
DMG_OUT="dist/${DMG_NAME}.dmg"

rm -rf "$STAGE" "$DMG_TMP" "$DMG_OUT"
mkdir -p "$STAGE"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "Project Switcher" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDRW \
  "$DMG_TMP" >/dev/null

hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT" >/dev/null
rm -f "$DMG_TMP"
rm -rf "$STAGE"

echo "已生成 $DMG_OUT"
echo "双击打开后，把「Project Switcher」拖到「Applications」即可安装。"
