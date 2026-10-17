#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
swift build -c release

app_dir="$repo_dir/dist/Password Entry.app"
extension_zip="$repo_dir/dist/password-entry-extension.zip"
installer_pkg="$repo_dir/dist/Password Entry.pkg"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$repo_dir/native-host/build"
cp .build/release/PasswordEntryDesktop "$app_dir/Contents/MacOS/Password Entry"
cp .build/release/PasswordEntryNativeHost "$repo_dir/native-host/build/password-entry-native-host"
"$repo_dir/scripts/build-icons.sh"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDisplayName</key><string>Password Entry</string>
  <key>CFBundleExecutable</key><string>Password Entry</string>
  <key>CFBundleIdentifier</key><string>com.passwordentry.desktop</string>
  <key>CFBundleName</key><string>Password Entry</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>CFBundleVersion</key><string>0.3.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

rm -f "$extension_zip"
(cd "$repo_dir" && zip -q -r "$extension_zip" manifest.json src -x '*.DS_Store')
pkgbuild --component "$app_dir" --install-location "/Applications" --identifier "com.passwordentry.desktop" --version "0.3.0" "$installer_pkg" >/dev/null

echo "Built: $app_dir"
echo "Native host: $repo_dir/native-host/build/password-entry-native-host"
echo "Chrome extension: $extension_zip"
echo "Installer package: $installer_pkg"
