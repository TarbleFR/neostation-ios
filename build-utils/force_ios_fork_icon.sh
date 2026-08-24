#!/bin/bash
set -euo pipefail

SRC="assets/images/fork-icon-valid.jpg"
ICON_DIR="ios/Runner/Assets.xcassets/AppIcon.appiconset"
CONTENTS="$ICON_DIR/Contents.json"

if [ ! -f "$SRC" ]; then
  echo "Missing fork icon source: $SRC" >&2
  exit 1
fi
if [ ! -f "$CONTENTS" ]; then
  echo "Missing iOS AppIcon Contents.json: $CONTENTS" >&2
  exit 1
fi

# Deliberately overwrite every concrete iOS AppIcon image referenced by the
# generated asset catalog. This runs *after* flutter_launcher_icons so no later
# icon generator can silently restore the upstream/default NeoStation icon.
python3 - "$CONTENTS" <<'PY' > /tmp/neostation_ios_icon_slots.txt
import json
import sys
from pathlib import Path

contents = Path(sys.argv[1])
data = json.loads(contents.read_text(encoding="utf-8"))
seen = set()
for image in data.get("images", []):
    filename = image.get("filename")
    size = image.get("size")
    scale = image.get("scale")
    if not filename or not size or not scale:
        continue
    try:
        logical = float(size.split("x", 1)[0])
        multiplier = float(scale.rstrip("x"))
        pixels = int(round(logical * multiplier))
    except Exception:
        continue
    key = (filename, pixels)
    if key in seen:
        continue
    seen.add(key)
    print(f"{pixels}\t{filename}")
PY

count=0
while IFS=$'\t' read -r pixels filename; do
  [ -n "$pixels" ] || continue
  [ -n "$filename" ] || continue
  sips -s format png -z "$pixels" "$pixels" "$SRC" --out "$ICON_DIR/$filename" >/dev/null
  count=$((count + 1))
done < /tmp/neostation_ios_icon_slots.txt
rm -f /tmp/neostation_ios_icon_slots.txt

if [ "$count" -eq 0 ]; then
  echo "No iOS AppIcon slots were generated from $CONTENTS" >&2
  exit 1
fi

# The marketing icon is the easiest invariant to verify and is required by the
# standard Flutter-generated AppIcon catalog.
MARKETING_ICON="$ICON_DIR/Icon-App-1024x1024@1x.png"
if [ ! -f "$MARKETING_ICON" ]; then
  echo "Fork icon override did not produce $MARKETING_ICON" >&2
  exit 1
fi

width=$(sips -g pixelWidth "$MARKETING_ICON" | awk '/pixelWidth/ {print $2}')
height=$(sips -g pixelHeight "$MARKETING_ICON" | awk '/pixelHeight/ {print $2}')
if [ "$width" != "1024" ] || [ "$height" != "1024" ]; then
  echo "Unexpected marketing icon dimensions: ${width}x${height}" >&2
  exit 1
fi

echo "Forced NeoStation fork branding into $count iOS AppIcon slots."
echo "Marketing icon: $MARKETING_ICON (${width}x${height})"
