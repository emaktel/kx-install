#!/usr/bin/env bash
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Run as root"; exit 1; }

systemctl stop pull-routing.timer pull-routing.service || true
systemctl disable pull-routing.timer || true
rm -f /etc/systemd/system/pull-routing.service /etc/systemd/system/pull-routing.timer
systemctl daemon-reload

if [ -f /etc/kamailio/kamailio.cfg.bak ]; then
  cp -a /etc/kamailio/kamailio.cfg.bak /etc/kamailio/kamailio.cfg
fi

rm -f /usr/local/sbin/pull-routing.sh /etc/kamailio/dest.map
echo "Uninstall complete (kamailio package remains)."
