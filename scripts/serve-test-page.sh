#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
port="${1:-8765}"
exec python3 -m http.server "$port" --bind 127.0.0.1 --directory "$repo_dir/tests/fixtures"
