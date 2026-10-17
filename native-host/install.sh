#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then echo "用法: $0 EXTENSION_ID" >&2; exit 1; fi
extension_id="$1"
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
build_dir="$script_dir/build"
mkdir -p "$build_dir"
"$repo_dir/scripts/build-macos.sh"

python3 - "$script_dir/host.template.json" "$build_dir/password-entry-native-host" "$extension_id" "$build_dir/com.passwordentry.auth.json" <<'PY'
import json
import pathlib
import sys
template = json.loads(pathlib.Path(sys.argv[1]).read_text())
template["path"] = sys.argv[2]
template["allowed_origins"] = [f"chrome-extension://{sys.argv[3]}/"]
pathlib.Path(sys.argv[4]).write_text(json.dumps(template, indent=2) + "\n")
PY

host_dir="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$host_dir"
cp "$build_dir/com.passwordentry.auth.json" "$host_dir/com.passwordentry.auth.json"
echo "已安装 macOS 辅助程序。"
