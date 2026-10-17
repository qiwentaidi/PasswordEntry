#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir"

db_name="${DB_NAME:-password-entry-share}"
db_location="${D1_LOCATION:-apac}"

echo "Checking Cloudflare authentication..."
npx wrangler whoami >/dev/null

find_database_id() {
  npx wrangler d1 list --json | python3 -c '
import json
import sys

name = sys.argv[1]
databases = json.load(sys.stdin)
for database in databases:
    if database.get("name") == name:
        print(database["uuid"])
        break
' "$db_name"
}

database_id="$(find_database_id)"
if [[ -z "$database_id" ]]; then
  echo "Creating D1 database: $db_name"
  npx wrangler d1 create "$db_name" --location "$db_location"
  database_id="$(find_database_id)"
fi

if [[ -z "$database_id" ]]; then
  echo "Unable to resolve the D1 database ID for $db_name" >&2
  exit 1
fi

python3 - "$database_id" "$db_name" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path("wrangler.jsonc")
config = json.loads(path.read_text())
database_id = sys.argv[1]
database_name = sys.argv[2]
for database in config.get("d1_databases", []):
    if database.get("binding") == "DB":
        database["database_id"] = database_id
        database["database_name"] = database_name
        break
else:
    raise SystemExit("wrangler.jsonc has no DB D1 binding")
path.write_text(json.dumps(config, indent=2) + "\n")
PY

echo "Using D1 database: $database_id"
npx wrangler d1 migrations apply "$db_name" --remote
npm run typecheck
npm run deploy

echo
echo "Deployment complete. Configure the resulting Worker URL in Password Entry under Settings → Share Service."
