#!/usr/bin/env bash
set -euo pipefail

: "${PGURL:?PGURL env is required (postgres://user:pass@host:port/db)}"
DEST_MAP="/etc/kamailio/dest.map"
MTREE_NAME="dest"

tmp="$(mktemp)"
# v_destinations (enabled) × v_domains(server_affinity) → "<number> <f1|f2>"
psql "$PGURL" -Atc "
SELECT
  CASE
    WHEN vd.destination_number LIKE '+%' THEN regexp_replace(vd.destination_number, '[^+0-9]', '', 'g')
    ELSE regexp_replace(vd.destination_number, '\D', '', 'g')
  END
  || ' ' ||
  vdms.server_affinity
FROM public.v_destinations vd
JOIN public.v_domains vdms USING (domain_uuid)
WHERE vd.destination_enabled = 'true'
  AND vd.destination_number IS NOT NULL
  AND vd.destination_number <> ''
ORDER BY 1;
" > "$tmp"

# sanity
if ! grep -Eq ' (f1|f2)$' "$tmp"; then
  echo "ERROR: export produced no f1/f2 rows" >&2
  rm -f "$tmp"
  exit 1
fi

install -o root -g root -m 0644 "$tmp" "$DEST_MAP"
rm -f "$tmp"

# Try hot-reload; fallback to restart if MI not available
if command -v kamcmd >/dev/null 2>&1; then
  kamcmd mtree.reload "$MTREE_NAME" || true
elif command -v kamctl >/dev/null 2>&1; then
  kamctl fifo "mtree.reload $MTREE_NAME" || true
else
  systemctl restart kamailio || true
fi
