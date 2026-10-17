#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$repo_dir/dist/Password Entry.app"
extension_zip="$repo_dir/dist/password-entry-extension.zip"
installer_pkg="$repo_dir/dist/Password Entry.pkg"
host_manifest="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.passwordentry.auth.json"

[[ -x "$app_dir/Contents/MacOS/Password Entry" ]] || { echo "缺少桌面端 app，可先运行 scripts/build-macos.sh" >&2; exit 1; }
[[ -f "$extension_zip" ]] || { echo "缺少 Chrome 扩展 zip，可先运行 scripts/build-macos.sh" >&2; exit 1; }
[[ -f "$installer_pkg" ]] || { echo "缺少 macOS 安装包，可先运行 scripts/build-macos.sh" >&2; exit 1; }
python3 - "$repo_dir/manifest.json" "$extension_zip" "$host_manifest" <<'PY'
import json
import pathlib
import sys
import zipfile

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert manifest.get("manifest_version") == 3
assert manifest.get("permissions") and "nativeMessaging" in manifest["permissions"]
for path in manifest.get("icons", {}).values():
    assert (pathlib.Path(sys.argv[1]).parent / path).is_file()
with zipfile.ZipFile(sys.argv[2]) as archive:
    names = set(archive.namelist())
    assert "manifest.json" in names and "src/background.js" in names and "src/content.js" in names
    for path in manifest.get("icons", {}).values(): assert path in names
if pathlib.Path(sys.argv[3]).exists():
    host = json.loads(pathlib.Path(sys.argv[3]).read_text())
    assert host.get("name") == "com.passwordentry.auth"
    assert pathlib.Path(host["path"]).is_file()
    assert pathlib.Path(host["path"]).stat().st_mode & 0o111
    assert len(host.get("allowed_origins", [])) == 1
print("Password Entry macOS 安装产物校验通过")
PY

if [[ -S "$HOME/Library/Application Support/Password Entry/agent.sock" ]]; then
  echo "桌面端 IPC socket: 运行中"
else
  echo "桌面端 IPC socket: 未运行（打开 app 后会出现）"
fi
