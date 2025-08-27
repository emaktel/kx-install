#!/usr/bin/env bash
set -euo pipefail

# Load env (if run by systemd unit, EnvironmentFile loads it)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$REPO_DIR/.env" ]; then
  # shellcheck disable=SC1090
  . "$REPO_DIR/.env"
fi

: "${POSTGREST_KEY:?POSTGREST_KEY missing}"
: "${POSTGREST_RO_DB_URL:?POSTGREST_RO_DB_URL missing}"
: "${POSTGREST_VIEW:?POSTGREST_VIEW missing}"
DEST_MAP_PATH="${DEST_MAP_PATH:-/etc/kamailio/dest.map}"

API_URL="${POSTGREST_RO_DB_URL%/}/$POSTGREST_VIEW?select=num,target"

tmpjson="$(mktemp)"
trap 'rm -f "$tmpjson"' EXIT

# 1) Pull JSON
http_code=$(
  curl -sS -w '%{http_code}' -o "$tmpjson" \
    -H "Authorization: Bearer ${POSTGREST_KEY}" \
    -H "Accept: application/json" \
    "$API_URL"
)

if [ "$http_code" != "200" ]; then
  echo "ERROR: PostgREST ${API_URL} returned HTTP ${http_code}" >&2
  echo "Body:" >&2
  cat "$tmpjson" >&2 || true
  exit 1
fi

# 2) Validate & render to map file
# Expected rows: [{"num":"+15145551212","target":"f1"}, ...]
if ! jq -e 'type=="array"' < "$tmpjson" >/dev/null 2>&1; then
  echo "ERROR: Unexpected JSON (not an array)" >&2
  cat "$tmpjson" >&2
  exit 1
fi

# Write pretty map (for humans)
sudo install -o "${KAM_USER:-kamailio}" -g "${KAM_GROUP:-kamailio}" -m 0644 /dev/null "$DEST_MAP_PATH"
jq -r '.[] | "\(.num) \(.target)"' < "$tmpjson" | sudo tee "$DEST_MAP_PATH" >/dev/null

# 3) Push into Kamailio mtree (best-effort; skip if Kamailio is down)
if ! command -v kamcmd >/dev/null 2>&1; then
  echo "WARN: kamcmd not found; skipping mtree update" >&2
  exit 0
fi

# Optional: detect if Kamailio is reachable
if ! kamcmd core.ps >/dev/null 2>&1; then
  echo "WARN: kamcmd cannot contact Kamailio (jsonrpcs). Is Kamailio running?" >&2
  exit 1
fi

# 3a) Build a set of current prefixes (if any) to allow deletion of stale routes.
# Use JSON output if available; else fall back to text parsing.
have_json=1
dump_json="$(mktemp)"; trap 'rm -f "$dump_json"' RETURN
if ! kamcmd -j mtree.dump dest > "$dump_json" 2>/dev/null; then
  have_json=0
fi

declare -A new_set=()
while read -r num target; do
  [ -z "$num" ] && continue
  new_set["$num"]="$target"
done < <(jq -r '.[] | "\(.num) \(.target)"' < "$tmpjson")

# Current entries
declare -A cur_set=()
if [ "$have_json" -eq 1 ]; then
  jq -r '.records[]? | "\(.tprefix)"' < "$dump_json" | while read -r p; do
    [ -z "$p" ] && continue
    cur_set["$p"]=1
  done
else
  # very crude text fallback (lines containing "tprefix: <value>")
  kamcmd mtree.dump dest 2>/dev/null | sed -n 's/.*tprefix:[[:space:]]*\([^ ]*\).*/\1/p' | while read -r p; do
    [ -z "$p" ] && continue
    cur_set["$p"]=1
  done
fi

# 3b) Remove stale prefixes
for p in "${!cur_set[@]}"; do
  if [ -z "${new_set["$p"]+x}" ]; then
    kamcmd mtree.rm dest "$p" >/dev/null 2>&1 || true
  fi
done

# 3c) Add/overwrite all new entries
while read -r num target; do
  [ -z "$num" ] && continue
  kamcmd mtree.add dest "$num" "$target" >/dev/null
done < <(jq -r '.[] | "\(.num) \(.target)"' < "$tmpjson")

echo "OK: mtree dest updated with $(printf '%s\n' "${!new_set[@]}" | wc -l) routes"
exit 0
