#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
[ -f "$REPO_DIR/.env" ] && . "$REPO_DIR/.env"

KAMCFG_PATH="${KAMCFG_PATH:-/etc/kamailio/kamailio.cfg}"
DEST_MAP_PATH="${DEST_MAP_PATH:-/etc/kamailio/dest.map}"
KAM_USER="${KAM_USER:-kamailio}"
KAM_GROUP="${KAM_GROUP:-kamailio}"

echo "==> Installing packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  kamailio kamailio-extra-modules curl jq >/dev/null

echo "==> Backup existing Kamailio config (if any)"
if [ -f "$KAMCFG_PATH" ]; then
  cp -a "$KAMCFG_PATH" "${KAMCFG_PATH}.bak.$(date +%s)"
fi

echo "==> Render kamailio.cfg"
mkdir -p "$(dirname "$KAMCFG_PATH")"

# Build carrier expression: ($si=="IP1") || ip.is_in_subnet("$si","CIDR")
CARRIER_EXPR=""
IFS=' ' read -r -a arr <<< "${CARRIER_WHITELIST:-}"
for item in "${arr[@]:-}"; do
  if [[ "$item" == */* ]]; then
    frag="ip.is_in_subnet(\"$si\",\"$item\")"
  else
    frag="($si==\"$item\")"
  fi
  if [ -z "$CARRIER_EXPR" ]; then CARRIER_EXPR="$frag"; else CARRIER_EXPR="$CARRIER_EXPR || $frag"; fi
done
[ -z "$CARRIER_EXPR" ] && CARRIER_EXPR='(1==0)'

ADVERTISE_FLAG=""
if [ -n "${SIP_ADVERTISE_ADDR:-}" ]; then
  ADVERTISE_FLAG="yes"
fi

sed -e "s|{{SIP_LISTEN_ADDR}}|${SIP_LISTEN_ADDR:-0.0.0.0}|g" \
    -e "s|{{SIP_LISTEN_PORT}}|${SIP_LISTEN_PORT:-5060}|g" \
    -e "s|{{F1_SIP}}|${F1_SIP:-sip:f1.emaktalk.com:5060;transport=udp}|g" \
    -e "s|{{F2_SIP}}|${F2_SIP:-sip:f2.emaktalk.com:5060;transport=udp}|g" \
    -e "s|{{CARRIER_EXPR}}|$CARRIER_EXPR|g" \
    -e "s|{{SIP_ADVERTISE_ADDR}}|${SIP_ADVERTISE_ADDR:-}|g" \
    -e "s|{{REPO_DIR}}|$REPO_DIR|g" \
    -e "s|{{PULL_MINUTES}}|${PULL_MINUTES:-1}|g" \
    -e "s|{{KAM_USER}}|${KAM_USER}|g" \
    -e "s|{{KAM_GROUP}}|${KAM_GROUP}|g" \
    -e "/#!ifdef ADVERTISE_SET/ s/ADVERTISE_SET/${ADVERTISE_FLAG:+ADVERTISE_SET}/" \
  "$REPO_DIR/templates/kamailio.cfg.tmpl" > "$KAMCFG_PATH"

echo "==> Prepare dest.map (for inspection)"
install -o "$KAM_USER" -g "$KAM_GROUP" -m 0644 /dev/null "$DEST_MAP_PATH"

echo "==> Install routing exporter"
install -D -o "$KAM_USER" -g "$KAM_GROUP" -m 0755 "$REPO_DIR/bin/pull-routing.sh" "/usr/local/bin/pull-routing.sh"

echo "==> Install systemd unit & timer"
svc="/etc/systemd/system/pull-routing.service"
tmr="/etc/systemd/system/pull-routing.timer"

sed -e "s|{{REPO_DIR}}|$REPO_DIR|g" \
    -e "s|{{KAM_USER}}|${KAM_USER}|g" \
    -e "s|{{KAM_GROUP}}|${KAM_GROUP}|g" \
  "$REPO_DIR/templates/pull-routing.service.tmpl" > "$svc"

sed -e "s|{{PULL_MINUTES}}|${PULL_MINUTES:-1}|g" \
  "$REPO_DIR/templates/pull-routing.timer.tmpl" > "$tmr"

echo "==> Reload systemd, enable services"
systemctl daemon-reload
systemctl enable --now pull-routing.timer
# Start kamailio after config in place (ignore failure – you can check logs)
systemctl enable kamailio || true
systemctl restart kamailio || true

echo "==> Done."
echo "Logs:"
echo "  journalctl -u kamailio -e -n 100"
echo "  journalctl -u pull-routing.service -e -n 50"
echo "Check map: head $DEST_MAP_PATH || true"
