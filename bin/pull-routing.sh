#!/usr/bin/env bash
set -euo pipefail

: "${POSTGREST_RO_DB_URL:?POSTGREST_RO_DB_URL required}"
: "${POSTGREST_KEY:?POSTGREST_KEY required}"
: "${POSTGREST_EXPORT_PATH:?POSTGREST_EXPORT_PATH required}"

DEST_MAP="/etc/kamailio/dest.map"
MTREE_NAME="dest"

BASE="${POSTGREST_RO_DB_URL%/}"
URL="${BASE}${POSTGREST_EXPORT_PATH}?select=num,target"

tmp="$(mktemp)"

# GET the view; expect JSON array with {num:"+E164", target:"f1|f2"}
curl -sS -X GET "$URL" \
  -H "Accept: application/json" \
  -H "Authorization: Bearer ${POSTGREST_KEY}" \
| jq -r '.[] | select(.num and .target) | "\(.num) \(.target)"' > "$tmp"

# Sanity: must output lines ending with f1/f2
if ! grep -Eq ' (f1|f2)$' "$tmp"; then
  echo "ERROR: export produced no f1/f2 rows from $URL" >&2
  rm -f "$tmp"
  exit 1
fi

install -o root -g root -m 0644 "$tmp" "$DEST_MAP"
rm -f "$tmp"

# Hot-reload mtree: prefer kamctl FIFO (mi_fifo loaded)
if command -v kamctl >/dev/null 2>&1; then
  kamctl fifo "mtree.reload $MTREE_NAME" || true
else
  systemctl restart kamailio || true
fi
