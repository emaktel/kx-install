#!/usr/bin/env bash
set -euo pipefail

# Env
: "${POSTGREST_RO_DB_URL:?missing}"
: "${POSTGREST_KEY:?missing}"
: "${ROUTING_VIEW:=edge_export_routing_view}"   # returns rows: { "num": "+15144479631", "target": "f1" }
: "${KAMCMD_BIN:=kamcmd}"

API_URL="${POSTGREST_RO_DB_URL%/}/${ROUTING_VIEW}?select=num,target"

tmp_new="$(mktemp)"
tmp_old="$(mktemp)"
trap 'rm -f "$tmp_new" "$tmp_old"' EXIT

# 1) Fetch desired state
http_code=$(curl -sS -o "$tmp_new" -w '%{http_code}' \
  -H "Authorization: Bearer ${POSTGREST_KEY}" \
  -H 'Accept: application/json' \
  "$API_URL")

if [[ "$http_code" != "200" ]]; then
  echo "ERROR: PostgREST $API_URL returned HTTP $http_code" >&2
  echo "Body:" >&2
  cat "$tmp_new" >&2
  exit 1
fi

# Ensure each line: num<TAB>target
jq -r '.[] | [.num,.target] | @tsv' "$tmp_new" \
  | awk -F'\t' 'NF==2 && $1!="" && $2!="" {print $1"\t"$2}' \
  | sort -u > "$tmp_new.sorted"

# 2) Get current state from Kamailio (what mtree has now)
# kamcmd mtree.dump dest  -> lines like: "<prefix> => <value>"
if ! $KAMCMD_BIN mtree.dump dest >/dev/null 2>&1; then
  echo "ERROR: kamcmd cannot contact Kamailio (jsonrpcs). Is Kamailio running and jsonrpcs loaded?" >&2
  exit 1
fi

$KAMCMD_BIN mtree.dump dest \
  | awk -F'=>| ' '/=>/ {gsub(/^ +| +$/,"",$1); gsub(/^ +| +$/,"",$2); if($1!=""&&$2!="") print $1"\t"$2}' \
  | sort -u > "$tmp_old.sorted"

# 3) Compute diffs
to_add="$(mktemp)"; to_rm="$(mktemp)"
trap 'rm -f "$tmp_new" "$tmp_old" "$to_add" "$to_rm" "$tmp_new.sorted" "$tmp_old.sorted"' EXIT

comm -13 "$tmp_old.sorted" "$tmp_new.sorted" > "$to_add"  # in NEW, not in OLD
comm -23 "$tmp_old.sorted" "$tmp_new.sorted" > "$to_rm"   # in OLD, not in NEW

# 4) Remove stale entries (by prefix; removes any value for that prefix)
while IFS=$'\t' read -r num target; do
  [[ -z "$num" ]] && continue
  echo "RM: $num"
  $KAMCMD_BIN mtree.rm dest "$num" >/dev/null || true
done < "$to_rm"

# 5) Add missing entries
while IFS=$'\t' read -r num target; do
  [[ -z "$num" || -z "$target" ]] && continue
  echo "ADD: $num -> $target"
  # best-effort remove first to avoid duplicate errors
  $KAMCMD_BIN mtree.rm dest "$num" >/dev/null || true
  $KAMCMD_BIN mtree.add dest "$num" "$target" >/dev/null
done < "$to_add"

echo "OK: mtree 'dest' synced."
