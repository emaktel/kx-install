#!/usr/bin/env bash
set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

# escape for sed with '#' delimiter
sed_escape() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g' -e 's/#/\\#/g' -e 's/\\/\\\\/g'; }

[ "$EUID" -eq 0 ] || die "Run as root (sudo)."

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT_DIR/.env" ] || die "Create .env from .env.example first."
# shellcheck disable=SC1090
source "$ROOT_DIR/.env"

LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
LISTEN_PORT="${LISTEN_PORT:-5060}"
ADVERTISE_ADDR="${ADVERTISE_ADDR:-}"
PULL_INTERVAL="${PULL_INTERVAL:-2m}"

[ -n "${F1_HOST:-}" ] || die "F1_HOST not set"
[ -n "${F2_HOST:-}" ] || die "F2_HOST not set"
[ -n "${CARRIER_SOURCES:-}" ] || die "CARRIER_SOURCES not set"
[ -n "${POSTGREST_RO_DB_URL:-}" ] || die "POSTGREST_RO_DB_URL not set"
[ -n "${POSTGREST_KEY:-}" ] || die "POSTGREST_KEY not set"
[ -n "${POSTGREST_EXPORT_PATH:-}" ] || die "POSTGREST_EXPORT_PATH not set"

echo "==> Installing packages"
apt-get update -y
apt-get install -y kamailio kamailio-extra-modules curl jq

need sed; need awk; need tr; need jq; need curl

echo "==> Prepare dbtext directory (for mtree init)"
DBTXT_DIR="/var/lib/kamailio/dbtext"
install -d -o kamailio -g kamailio "$DBTXT_DIR"
# Minimal db_text 'version' table so URL is valid even if unused
if [ ! -f "$DBTXT_DIR/version" ]; then
  printf 'table_name(str) table_version(int)\n' > "$DBTXT_DIR/version"
  chown kamailio:kamailio "$DBTXT_DIR/version"
fi

echo "==> Backup existing Kamailio config (if any)"
if [ -f /etc/kamailio/kamailio.cfg ] && [ ! -f /etc/kamailio/kamailio.cfg.bak ]; then
  cp -a /etc/kamailio/kamailio.cfg /etc/kamailio/kamailio.cfg.bak || true
fi

echo "==> Render kamailio.cfg"
CFG_TMPL="$ROOT_DIR/templates/kamailio.cfg.tmpl"
CFG_OUT="/etc/kamailio/kamailio.cfg"

# Build carrier allow expression
CARRIER_EXPR=""
IFS=',' read -ra SRC_ARR <<< "$CARRIER_SOURCES"
for raw in "${SRC_ARR[@]}"; do
  src="$(echo "$raw" | xargs)"
  [ -z "$src" ] && continue
  if [[ "$src" == */* ]]; then
    expr="ipops.is_in_subnet(\"\$si\",\"$src\")"
  else
    expr="(\$si==\"$src\")"
  fi
  if [ -z "$CARRIER_EXPR" ]; then CARRIER_EXPR="$expr"; else CARRIER_EXPR="$CARRIER_EXPR || $expr"; fi
done
[ -n "$CARRIER_EXPR" ] || die "CARRIER_SOURCES produced empty expression"

# Advertise suffix for listen line
if [ -n "$ADVERTISE_ADDR" ]; then
  ADVERTISE_SUFFIX=" advertise ${ADVERTISE_ADDR}:${LISTEN_PORT}"
else
  ADVERTISE_SUFFIX=""
fi

# Escape for sed
ESC_LISTEN_ADDR="$(sed_escape "$LISTEN_ADDR")"
ESC_LISTEN_PORT="$(sed_escape "$LISTEN_PORT")"
ESC_ADVERTISE_SUFFIX="$(sed_escape "$ADVERTISE_SUFFIX")"
ESC_CARRIER_EXPR="$(sed_escape "$CARRIER_EXPR")"
ESC_F1_HOST="$(sed_escape "$F1_HOST")"
ESC_F2_HOST="$(sed_escape "$F2_HOST")"

tmpcfg="$(mktemp)"
sed -e "s#__LISTEN_ADDR__#${ESC_LISTEN_ADDR}#g" \
    -e "s#__LISTEN_PORT__#${ESC_LISTEN_PORT}#g" \
    -e "s#__ADVERTISE_SUFFIX__#${ESC_ADVERTISE_SUFFIX}#g" \
    -e "s#__CARRIER_EXPR__#${ESC_CARRIER_EXPR}#g" \
    -e "s#__F1_HOST__#${ESC_F1_HOST}#g" \
    -e "s#__F2_HOST__#${ESC_F2_HOST}#g" \
    "$CFG_TMPL" > "$tmpcfg"
install -o root -g root -m 0644 "$tmpcfg" "$CFG_OUT"
rm -f "$tmpcfg"

echo "==> Install routing exporter"
install -D -o root -g root -m 0755 "$ROOT_DIR/bin/pull-routing.sh" /usr/local/sbin/pull-routing.sh

echo "==> Install systemd unit & timer"
SVC_TMPL="$ROOT_DIR/templates/pull-routing.service.tmpl"
TMR_TMPL="$ROOT_DIR/templates/pull-routing.timer.tmpl"
SVC_OUT="/etc/systemd/system/pull-routing.service"
TMR_OUT="/etc/systemd/system/pull-routing.timer"

svc_tmp="$(mktemp)"
tmr_tmp="$(mktemp)"

# escape slashes for sed here
sed -e "s#__POSTGREST_RO_DB_URL__#${POSTGREST_RO_DB_URL//\//\\/}#g" \
    -e "s#__POSTGREST_KEY__#${POSTGREST_KEY//\//\\/}#g" \
    -e "s#__POSTGREST_EXPORT_PATH__#${POSTGREST_EXPORT_PATH//\//\\/}#g" \
    "$SVC_TMPL" > "$svc_tmp"

sed -e "s#__PULL_INTERVAL__#${PULL_INTERVAL}#g" \
    "$TMR_TMPL" > "$tmr_tmp"

install -o root -g root -m 0644 "$svc_tmp" "$SVC_OUT"
install -o root -g root -m 0644 "$tmr_tmp" "$TMR_OUT"
rm -f "$svc_tmp" "$tmr_tmp"

echo "==> Reload systemd, enable services"
systemctl daemon-reload
systemctl enable --now kamailio
systemctl enable --now pull-routing.timer
# run a first sync; if Kamailio not fully up yet, it's fine to retry later via timer
systemctl start pull-routing.service || true

echo "==> Done."
echo "Logs:"
echo "  journalctl -u kamailio -e -n 100"
echo "  journalctl -u pull-routing.service -e -n 50"
echo "Check tree: kamcmd mtree.dump dest | head"
