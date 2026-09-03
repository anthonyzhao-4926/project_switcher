#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BIN=".build/release/ProjectSwitcher"
if [[ ! -x "$BIN" ]]; then
  echo "找不到 $BIN，请先运行: swift build -c release" >&2
  exit 1
fi

APP="dist/Project Switcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/ProjectSwitcher"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/cursor-extension"
cp cursor-extension/package.json cursor-extension/extension.js "$APP/Contents/Resources/cursor-extension/"

if command -v codesign >/dev/null 2>&1; then
  bash scripts/sign.sh "$APP"
fi

echo "已生成 $APP"
