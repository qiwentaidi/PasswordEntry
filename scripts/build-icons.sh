#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_png="$repo_dir/design/icon.png"
transparent_master="$repo_dir/.build/password-entry-icon-transparent.png"
chrome_dir="$repo_dir/src/icons"
iconset_dir="$repo_dir/.build/AppIcon.iconset"
app_icon="$repo_dir/dist/Password Entry.app/Contents/Resources/AppIcon.icns"

mkdir -p "$chrome_dir" "$iconset_dir"
[[ -f "$source_png" ]] || { echo "缺少图标源文件: $source_png" >&2; exit 1; }
master="$source_png"
mkdir -p "$(dirname "$transparent_master")"
swift "$repo_dir/scripts/make-transparent-icon.swift" "$source_png" "$transparent_master"

for size in 16 32 48 128; do
  sips -z "$size" "$size" "$transparent_master" --out "$chrome_dir/icon${size}.png" >/dev/null
done

for spec in \
  "icon_16x16.png 16" "icon_16x16@2x.png 32" \
  "icon_32x32.png 32" "icon_32x32@2x.png 64" \
  "icon_128x128.png 128" "icon_128x128@2x.png 256" \
  "icon_256x256.png 256" "icon_256x256@2x.png 512" \
  "icon_512x512.png 512" "icon_512x512@2x.png 1024"; do
  name="${spec% *}"; size="${spec##* }"
  sips -z "$size" "$size" "$master" --out "$iconset_dir/$name" >/dev/null
done

mkdir -p "$(dirname "$app_icon")"
iconutil -c icns "$iconset_dir" -o "$app_icon"
echo "Built icon assets: $chrome_dir and $app_icon"
