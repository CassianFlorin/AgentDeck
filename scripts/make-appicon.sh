#!/usr/bin/env bash
# Render the icon and build Resources/Assets.xcassets/AppIcon.appiconset.
#   scripts/make-appicon.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SET="$ROOT/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$SET"

MASTER="$ROOT/Resources/AppIcon-1024.png"   # also used by the README
swift "$ROOT/scripts/render-icon.swift" "$MASTER"

# macOS sizes: 16, 32, 128, 256, 512 at @1x and @2x.
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$MASTER" --out "$SET/icon_${s}.png" >/dev/null
  d=$((s * 2))
  if [ "$d" -eq 1024 ]; then
    cp "$MASTER" "$SET/icon_${s}@2x.png"
  else
    sips -z "$d" "$d" "$MASTER" --out "$SET/icon_${s}@2x.png" >/dev/null
  fi
done

cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "size" : "16x16", "scale" : "1x", "filename" : "icon_16.png" },
    { "idiom" : "mac", "size" : "16x16", "scale" : "2x", "filename" : "icon_16@2x.png" },
    { "idiom" : "mac", "size" : "32x32", "scale" : "1x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32", "scale" : "2x", "filename" : "icon_32@2x.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "1x", "filename" : "icon_128.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "2x", "filename" : "icon_128@2x.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "1x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "2x", "filename" : "icon_256@2x.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "1x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "2x", "filename" : "icon_512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
cat > "$ROOT/Resources/Assets.xcassets/Contents.json" <<'JSON'
{ "info" : { "author" : "xcode", "version" : 1 } }
JSON
echo "==> $SET"
