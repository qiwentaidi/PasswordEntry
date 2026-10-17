#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
extension_id="${1:-}"
"$repo_dir/scripts/build-macos.sh"

applications_dir="$HOME/Applications"
mkdir -p "$applications_dir"
rm -rf "$applications_dir/Password Entry.app"
ditto "$repo_dir/dist/Password Entry.app" "$applications_dir/Password Entry.app"

if [[ -n "$extension_id" ]]; then
  "$repo_dir/native-host/install.sh" "$extension_id"
else
  echo "未提供扩展 ID；请在 chrome://extensions 加载 dist/password-entry-extension.zip 解压后的目录后，再运行 native-host/install.sh EXTENSION_ID。"
fi

open "$applications_dir/Password Entry.app"
echo "Password Entry 已安装到 $applications_dir/Password Entry.app"
