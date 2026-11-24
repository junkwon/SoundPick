#!/usr/bin/env bash
# Regenerates the app icon from Design/icon-source.png: make-icon.swift
# enlarges the note by 50% and writes the 1024px master, which is then
# resized into every slot of AppIcon.appiconset.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SET="$ROOT/Sources/PullTube/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$SET"
swift "$ROOT/scripts/make-icon.swift" "$ROOT/Design/icon-source.png" "$SET/icon_1024.png" 1.5
for px in 16 32 64 128 256 512; do
  sips -s format png -z $px $px "$SET/icon_1024.png" --out "$SET/icon_$px.png" >/dev/null
done
cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_64.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
printf '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' > "$SET/../Contents.json"

# The same artwork as a plain image, which the app applies to itself at launch
# as a custom file icon (see AppIcon.swift) so macOS shows the bare folder.
FOLDER="$SET/../FolderIcon.imageset"
mkdir -p "$FOLDER"
cp "$SET/icon_1024.png" "$FOLDER/folder_1024.png"
cat > "$FOLDER/Contents.json" <<'JSON'
{
  "images" : [ { "idiom" : "universal", "filename" : "folder_1024.png" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "Icon written to $SET"
