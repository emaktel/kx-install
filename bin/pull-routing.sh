#!/usr/bin/env bash
set -euo pipefail

: "${POSTGREST_RO_DB_URL:?POSTGREST_RO_DB_URL required}"
: "${POSTGREST_KEY:?POSTGREST_KEY required}"
: "${POSTGREST_EXPORT_PATH:?POSTGREST_EXPORT_PATH required}"
: "${KAMCMD_BIN:=kamcmd}"

BASE="${POSTGREST_RO_DB_URL%/}"
PATH_SEG="${POSTGREST_EXPORT_PATH#/}"       # strip leading slash if present
URL="${BASE}/${PATH_SEG}?select=num,target"

tmp_json="$(mktemp)"
tmp_new="$(mktemp)"
tmp_old="$(mktemp)"
trap 'rm -f "$tmp_json" "$tmp_new" "$tmp_old" "$tmp_new.sorted" "$tmp_old.sorted" "$to_add" "$to_rm"' EXIT

# 1) fetch desired state
status="$(curl -sS -w '%{http_code}' -o "$tmp_json" \
  -H "Accept: application/json" \
  -H "Authorization: Bearer ${POSTGREST_KEY}" \
  "$URL")"
if [ "$status" != "200" ]; then
  echo "ERROR: PostgREST $URL returned HTTP $status" >&2
  sed -n '1,200p' "$tmp_json" >&2
  exit 1
fi

# JSON -> TSV (num \t target), unique/sorted; allow empty
if ! jq -er '.[] | select(.num and .target) | "\(.num)\t\(.target)"' < "$tmp_json" \
    | sort -u > "$tmp_new.sorted"; then
  : > "$tmp_new.sorted"
fi

# 2) current in-memory state
if ! $KAMCMD_BIN mtree.dump dest >/dev/null 2>&1; then
  echo "ERROR: kamcmd cannot contact Kamailio (jsonrpcs). Is Kamailio running?" >&2
  exit 1
fi

$KAMCMD_BIN mtree.dump dest \
  | awk -F'=>| ' '/=>/ {gsub(/^ +| +$/,"",$1); gsub(/^ +| +$/,"",$2); if($1!=""&&$2!="") print $1"\t"$2}' \
  | sort -u > "$tmp_old.sorted"

# 3) diffs
to_add="$(mktemp)"; to_rm="$(mktemp)"
comm -13 "$tmp_old.sorted" "$tmp_new.sorted" > "$to_add"  # in NEW, not in OLD
comm -23 "$tmp_old.sorted" "$tmp_new.sorted" > "$to_rm"   # in OLD, not in NEW

# 4) apply removals (by prefix)
while IFS=$'\t' read -r num _; do
  [ -n "${num:-}" ] || continue
  echo "RM: $num"
  $KAMCMD_BIN mtree.rm dest "$num" >/dev/null || true
done < "$to_rm"

# 5) apply adds
while IFS=$'\t' read -r num target; do
  [ -n "${num:-}" ] && [ -n "${target:-}" ] || continue
  echo "ADD: $num -> $target"
  $KAMCMD_BIN mtree.rm dest "$num" >/dev/null || true
  $KAMCMD_BIN mtree.add dest "$num" "$target" >/dev/null
done < "$to_add"

echo "OK: mtree 'dest' synced."
