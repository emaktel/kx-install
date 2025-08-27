#!/usr/bin/env bash
set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

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

if [ -n "$ADVERTISE_ADDR" ]; then
  ADVERTISE_LINE="advertise \"$ADVERTISE_ADDR\":$LISTEN_PORT"
else
  ADVERTISE_LINE="# advertise not set"
fi

tmpcfg="$(mktemp)"
sed -e "s#__LISTEN_ADDR__#$LISTEN_ADDR#g" \
    -e "s#__LISTEN_PORT__#$LISTEN_PORT#g" \
    -e "s#__ADVERTISE_LINE__#$ADVERTISE_LINE#g" \
    -e "s#__CARRIER_EXPR__#$CARRIER_EXPR#g" \
    -e "s#__F1_HOST__#$F1_HOST#g" \
    -e "s#__F2_HOST__#$F2_HOST#g" \
    "$CFG_TMPL" > "$tmpcfg"
install -o root -g root -m 0644 "$tmpcfg" "$CFG_OUT"
rm -f "$tmpcfg"

echo "==> Create empty mtree map"
install -o root -g root -m 0644 /dev/null /etc/kamailio/dest.map

echo "==> Install routing exporter"
install -D -o root -g root -m 0755 "$ROOT_DIR/bin/pull-routing.sh" /usr/local/sbin/pull-routing.sh

echo "==> Install systemd unit & timer"
SVC_OUT="/etc/systemd/system/pull-routing.service"
TMR_OUT="/etc/systemd/system/pull-routing.timer"

svc_tmp="$(mktemp)"
tmr_tmp="$(mktemp)"

sed -e "s#__POSTGREST_RO_DB_URL__#${POSTGREST_RO_DB_URL//\//\\/}#g" \
    -e "s#__POSTGREST_KEY__#${POSTGREST_KEY//\//\\/}#g" \
    -e "s#__POSTGREST_EXPORT_PATH__#${POSTGREST_EXPORT_PATH//\//\\/}#g" \
    "$ROOT_DIR/templates/pull-routing.service.tmpl" > "$svc_tmp"

sed -e "s#__PULL_INTERVAL__#$PULL_INTERVAL#g" \
    "$ROOT_DIR/templates/pull-routing.timer.tmpl" > "$tmr_tmp"

install -o root -g root -m 0644 "$svc_tmp" "$SVC_OUT"
install -o root -g root -m 0644 "$tmr_tmp" "$TMR_OUT"
rm -f "$svc_tmp" "$tmr_tmp"

systemctl daemon-reload
systemctl enable --now pull-routing.timer
systemctl start pull-routing.service || true

echo "==> Enable & start Kamailio"
systemctl enable --now kamailio

echo "==> Done."
echo "Logs:"
echo "  journalctl -u kamailio -e -n 100"
echo "  journalctl -u pull-routing.service -e -n 50"
echo "Check map: head /etc/kamailio/dest.map"
