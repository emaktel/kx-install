#!/usr/bin/env bash
set -euo pipefail

: "${POSTGREST_RO_DB_URL:?POSTGREST_RO_DB_URL required}"
: "${POSTGREST_KEY:?POSTGREST_KEY required}"
: "${POSTGREST_EXPORT_PATH:?POSTGREST_EXPORT_PATH required}"

DEST_MAP="/etc/kamailio/dest.map"
MTREE_NAME="dest"

BASE="${POSTGREST_RO_DB_URL%/}"
URL="${BASE}${POSTGREST_EXPORT_PATH}?select=num,target"

tmp_json="$(mktemp)"
tmp_out="$(mktemp)"

# Fetch JSON and capture HTTP status
status="$(curl -sS -w '%{http_code}' -o "$tmp_json" \
  -H "Accept: application/json" \
  -H "Authorization: Bearer ${POSTGREST_KEY}" \
  "$URL")"

if [ "$status" != "200" ]; then
  echo "ERROR: PostgREST $URL returned HTTP $status" >&2
  echo "Body:" >&2; sed -n '1,200p' "$tmp_json" >&2
  rm -f "$tmp_json" "$tmp_out"
  exit 1
fi

# Parse → "<num> <target>" lines (allow empty)
if ! jq -er '.[] | select(.num and .target) | "\(.num) \(.target)"' < "$tmp_json" > "$tmp_out"; then
  echo "WARN: JSON parse produced no rows; writing empty dest.map" >&2
  : > "$tmp_out"
fi

# Install map atomically
install -o root -g root -m 0644 "$tmp_out" "$DEST_MAP"
rm -f "$tmp_json" "$tmp_out"

# Hot-reload mtree (best effort)
KAMCTL="$(command -v kamctl || true)"
if [ -n "$KAMCTL" ] && [ -S /var/run/kamailio/kamailio_fifo ]; then
  "$KAMCTL" fifo "mtree.reload $MTREE_NAME" || true
else
  systemctl reload kamailio || systemctl restart kamailio || true
fi
