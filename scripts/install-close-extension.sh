#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT_SRC="$ROOT/cursor-extension"
DEST="$HOME/.cursor/extensions/local.project-switcher-close-0.1.1"
VSIX="$ROOT/.build/local.project-switcher-close-0.1.1.vsix"
OBSOLETE="$HOME/.cursor/extensions/.obsolete"
EXT_JSON="$HOME/.cursor/extensions/extensions.json"

rm -rf "$HOME/.cursor/extensions/zhaoxin.project-switcher-close-0.1.0"
rm -rf "$DEST"
mkdir -p "$DEST" "$(dirname "$VSIX")"
cp "$EXT_SRC/package.json" "$EXT_SRC/extension.js" "$EXT_SRC/.vsixmanifest" "$DEST/"

python3 - <<'PY'
import json, os, time
obsolete_path = os.path.expanduser("~/.cursor/extensions/.obsolete")
if os.path.exists(obsolete_path):
    data = json.load(open(obsolete_path))
    removed = False
    for key in list(data):
        if "project-switcher-close" in key:
            del data[key]
            removed = True
    if removed:
        json.dump(data, open(obsolete_path, "w"), separators=(",", ":"))

ext_json = os.path.expanduser("~/.cursor/extensions/extensions.json")
entries = json.load(open(ext_json))
entries = [e for e in entries if e.get("identifier", {}).get("id") not in (
    "zhaoxin.project-switcher-close",
    "local.project-switcher-close",
)]
dest = os.path.expanduser("~/.cursor/extensions/local.project-switcher-close-0.1.1")
entries.append({
    "identifier": {"id": "local.project-switcher-close"},
    "version": "0.1.1",
    "location": {"$mid": 1, "path": dest, "scheme": "file"},
    "relativeLocation": "local.project-switcher-close-0.1.1",
    "metadata": {
        "isApplicationScoped": False,
        "isMachineScoped": False,
        "isBuiltin": False,
        "installedTimestamp": int(time.time() * 1000),
        "pinned": True,
        "source": "vsix",
    },
})
json.dump(entries, open(ext_json, "w"), indent=None)
print("extensions.json 已写入 local.project-switcher-close")
PY

rm -f "$VSIX"
TMP="$(mktemp -d)"
mkdir -p "$TMP/extension"
cp "$EXT_SRC/package.json" "$EXT_SRC/extension.js" "$TMP/extension/"
cp "$EXT_SRC/.vsixmanifest" "$TMP/extension.vsixmanifest"
printf '%s\n' '<?xml version="1.0" encoding="utf-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="json" ContentType="application/json"/><Default Extension="js" ContentType="application/javascript"/><Default Extension="vsixmanifest" ContentType="text/xml"/></Types>' > "$TMP/[Content_Types].xml"
(
  cd "$TMP"
  zip -q -r "$VSIX" extension extension.vsixmanifest "[Content_Types].xml"
)

CLI="/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
if [[ -x "$CLI" ]]; then
  "$CLI" --install-extension "$VSIX" --force >/dev/null 2>&1 || true
fi

if "$CLI" --list-extensions 2>/dev/null | grep -q 'project-switcher-close'; then
  echo "Cursor 已识别 local.project-switcher-close"
else
  echo "警告: cursor --list-extensions 仍未列出该扩展，已写入 extensions.json"
fi
