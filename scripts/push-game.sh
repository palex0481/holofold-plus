#!/usr/bin/env bash
# Copies a game you dumped yourself onto Apple Vision Pro, into Holofold's Documents folder.
# Holofold installs .cia files from there by itself the next time it starts.
#
#   scripts/push-game.sh <file.cia|.3ds|.cci|.cxi|.3dsx> [device UDID] [bundle ID]
#   scripts/push-game.sh --textures <folder named after the title ID> [device UDID] [bundle ID]
#
# --textures copies a texture pack folder to Documents/Azahar/load/textures/<title ID>/.
#
# Only ever adds files: it never uses --remove-existing-content (which would wipe the app's
# whole data container, games and saves included).
set -euo pipefail
textures=0
if [ "${1:-}" = "--textures" ]; then textures=1; shift; fi
file="${1:?usage: push-game.sh [--textures] <game file or texture folder> [device UDID] [bundle ID]}"
file="${file%/}"
device="${2:-}"
bundle="${3:-$(sed -n 's/^HOLOFOLD_BUNDLE_ID *= *//p' "$(dirname "$0")/../App/Config/Local.xcconfig" 2>/dev/null | tail -1)}"
[ -n "$bundle" ] || { echo "error: give the bundle ID, or set HOLOFOLD_BUNDLE_ID in App/Config/Local.xcconfig" >&2; exit 2; }
if [ -z "$device" ]; then
  device=$(xcrun devicectl list devices 2>/dev/null | awk '/Vision Pro/ && /connected/ && /physical/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)
  [ -n "$device" ] || { echo "error: no connected Vision Pro found; pass its UDID" >&2; exit 2; }
fi
copy() {
  xcrun devicectl device copy to --device "$device" --domain-type appDataContainer \
    --domain-identifier "$bundle" --source "$1" --destination "$2"
}

if [ "$textures" -eq 1 ]; then
  [ -d "$file" ] || { echo "error: $file is not a folder" >&2; exit 2; }
  title=$(basename "$file")
  [[ "$title" =~ ^[0-9A-Fa-f]{16}$ ]] || { echo "error: the folder must be named after the game's 16-digit title ID" >&2; exit 2; }
  [ -f "$file/pack.json" ] || echo "warning: no pack.json in $file" >&2
  copy "$file" "Documents/Azahar/load/textures/$title"
  echo "Copied. Start the game in Holofold to use the textures."
  exit 0
fi

python3 -I "$(dirname "$0")/tools/ciacheck.py" "$file" 2>/dev/null || case "$file" in *.cia|*.CIA) echo "warning: see above — Azahar only installs decrypted dumps" >&2 ;; esac
copy "$file" "Documents/$(basename "$file")"
echo "Copied. Open Holofold on the headset to install and play it."
