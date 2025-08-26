#!/usr/bin/env bash
set -euo pipefail

# --- helpers ---
die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

# --- require root ---
[ "$EUID" -eq 0 ] || die "Run as root (sudo)."

# --- load env ---
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT_DIR/.env" ] || die "Create .env from .env.example first."
# shellcheck disable=SC1090
source "$ROOT_DIR/.env"

# defaults
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
LISTEN_PORT="${LISTEN_PORT:-5060}"
ADVERTISE_ADDR="${ADVERTISE_ADDR:-}"
PULL_INTERVAL="${PULL_INTERVAL:-2m}"

# minimal validation
[ -n "${F1_HOST:-}" ] || die "F1_HOST not set"
[ -n "${F2_HOST:-}" ] || die "F2_HOST not set"
[ -n "${CARRIER_SOURCES:-}" ] || die "CARRIER_SOURCES not set"
[ -n "${PGURL:-}" ] || die "PGURL not set"

echo "==> Installing packages"
apt-get update -y
apt-get install -y kamailio postgresql-client curl jq

need sed
need tr
need awk

echo "==> Backing up any existing Kamailio config"
if [ -f /etc/kamailio/kamailio.cfg ] && [ ! -f /etc/kamailio/kamailio.cfg.bak ]; then
  cp -a /etc/kamailio/kamailio.cfg /etc/kamailio/kamailio.cfg.bak || true
fi

echo "==> Rendering kamailio.cfg from template"
CFG_TMPL="$ROOT_DIR/templates/kamailio.cfg.tmpl"
CFG_OUT="/etc/kamailio/kamailio.cfg"

# Build carrier expression: IPs use $si=="ip"; CIDRs use ipops.is_in_subnet("$si","cidr")
CARRIER_EXPR=""
IFS=',' read -ra SRC_ARR <<< "$CARRIER_SOURCES"
for raw in "${SRC_ARR[@]}"; do
  src="$(echo "$raw" | xargs)" # trim
  [ -z "$src" ] && continue
  if [[ "$src" == */* ]]; then
    expr="ipops.is_in_subnet(\"\$si\",\"$src\")"
  else
    expr="(\$si==\"$src\")"
  fi
  if [ -z "$CARRIER_EXPR" ]; then CARRIER_EXPR="$expr"; else CARRIER_EXPR="$CARRIER_EXPR || $expr"; fi
done
[ -n "$CARRIER_EXPR" ] || die "CARRIER_SOURCES built empty expression"

# Advertise line
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

echo "==> Creating empty /etc/kamailio/dest.map"
install -o root -g root -m 0644 /dev/null /etc/kamailio/dest.map

echo "==> Installing routing exporter"
install -D -o root -g root -m 0755 "$ROOT_DIR/bin/pull-routing.sh" /usr/local/sbin/pull-routing.sh

echo "==> Installing systemd unit & timer"
SVC_OUT="/etc/systemd/system/pull-routing.service"
TMR_OUT="/etc/systemd/system/pull-routing.timer"

sed -e "s#__PGURL__#${PGURL//\//\\/}#g" "$ROOT_DIR/templates/pull-routing.service.tmpl" > "$SVC_OUT"
sed -e "s#__PULL_INTERVAL__#$PULL_INTERVAL#g" "$ROOT_DIR/templates/pull-routing.timer.tmpl" > "$TMR_OUT"

systemctl daemon-reload
systemctl enable --now pull-routing.timer
systemctl start pull-routing.service || true

echo "==> Enabling & starting Kamailio"
systemctl enable --now kamailio

echo "==> Done."
echo "Useful commands:"
echo "  journalctl -u kamailio -e -n 100"
echo "  journalctl -u pull-routing.service -e -n 50"
echo "  head /etc/kamailio/dest.map"
